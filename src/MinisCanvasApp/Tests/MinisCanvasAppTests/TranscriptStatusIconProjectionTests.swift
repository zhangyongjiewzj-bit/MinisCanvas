import AppKit
import Foundation
import Testing
import SwiftUI
@testable import MinisCanvasApp

@Suite("Goal22 production status icon projection and copy", .serialized)
@MainActor
struct TranscriptStatusIconProjectionTests {
    private func attachmentRanges(_ text: NSAttributedString) -> [NSRange] {
        var result: [NSRange] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { result.append(range) }
        }
        return result
    }

    @Test func leadingStatusMappingPreservesOriginalSourcesAndMarkdownBoundaries() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let body = "⏳ pending\n⏹ stopped\n⚠️ caution\n❌ failed\n✅ done\n🪄 compact"
        let redactor = ChatTranscriptRedactor(secretValues: [])
        for role in [ChatRole.user, .assistant, .tool, .system] {
            let message = ChatMessageUI(role: role, content: body)
            let original = ChatTranscriptFormatter.formattedMessage(message, baseSize: 13, redactor: nil)
            let document = ChatTranscriptFormatter.formattedDocument([message]).attributedString
            #expect(attachmentRanges(document).count == 6)
            #expect(!document.string.contains("\u{FE0F}"))
            #expect(ChatTranscriptStatusIconProjection.copyText(document) == original.string)
            let accessible = ChatTranscriptStatusIconProjection.accessibilityText(document)
            #expect(!accessible.contains("\u{FFFC}"))
            for label in ["生成中", "已停止", "警告", "失败", "成功", "上下文整理"] {
                #expect(accessible.contains(label))
            }
            #expect(message.content == body)
            #expect(ChatTranscriptFormatter.plainText([message]).contains(body))
            #expect(ChatTranscriptFormatter.persistedEntries([message]).first?.text == body)
            #expect(SessionMarkdownExport.replyText(nth: 1, messages: [ChatMessageUI(role: .assistant, content: body)], redactor: redactor) == body)
            #expect(SessionMarkdownExport.markdown(title: "合成", messages: [message], redactor: redactor).contains(body))
        }
        let ignored = "行中 ⚠️ 原文\n\n`⚠️ inline`\n\n```text\n⚠️ fenced\n```\n\n| 列 | 说明 |\n|---|---|\n| ⚠️ cell | 保留 |"
        let ignoredMessage = ChatMessageUI(role: .assistant, content: ignored)
        let ignoredDocument = ChatTranscriptFormatter.formattedDocument([ignoredMessage]).attributedString
        // 1448 expands the closed set into prose; code and table still exclude it.
        #expect(attachmentRanges(ignoredDocument).count == 1)
        #expect(ignoredDocument.string.contains("行中 \u{FFFC} 原文"))
        #expect(ChatTranscriptStatusIconProjection.copyText(ignoredDocument).contains("行中 ⚠️ 原文"))
        for text in ["⚠️ inline", "⚠️ fenced", "⚠️ cell"] {
            #expect(ignoredDocument.string.contains(text))
        }
        let extendedEmoji = "😀 👨‍👩‍👧‍👦 👍🏽 🇨🇳 1️⃣ ⚠️\u{200D}↔️ ✅🏽 ⏳\u{200D}😀"
        let extendedMessage = ChatMessageUI(role: .assistant, content: extendedEmoji)
        let extendedDocument = ChatTranscriptFormatter.formattedDocument([extendedMessage]).attributedString
        #expect(attachmentRanges(extendedDocument).isEmpty)
        #expect(extendedDocument.string.contains(extendedEmoji))
        #expect(ChatTranscriptStatusIconProjection.copyText(extendedDocument)
            == ChatTranscriptFormatter.formattedMessage(extendedMessage, baseSize: 13, redactor: nil).string)
        for example in ["测试对话已成功创建。✅", "⚠️注意", "- ✅ 完成", "已完成✅继续"] {
            let message = ChatMessageUI(role: .assistant, content: example)
            let document = ChatTranscriptFormatter.formattedDocument([message]).attributedString
            #expect(attachmentRanges(document).count == 1)
            #expect(ChatTranscriptStatusIconProjection.copyText(document)
                == ChatTranscriptFormatter.formattedMessage(message, baseSize: 13, redactor: nil).string)
            #expect(ChatTranscriptFormatter.persistedEntries([message]).first?.text == example)
            #expect(ChatTranscriptFormatter.plainText([message]).contains(example))
            #expect(SessionMarkdownExport.markdown(title: "同形样例", messages: [message], redactor: redactor).contains(example))
        }
        for visibleLeading in ["> ⚠️ 引用", "**⚠️ 强调**"] {
            let document = ChatTranscriptFormatter.formattedDocument([
                ChatMessageUI(role: .assistant, content: visibleLeading)
            ]).attributedString
            #expect(attachmentRanges(document).count == 1)
        }
    }

    @Test func publicSanitizerKeepsForeignAttachmentsClosedEvenAfterProjection() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let foreign = NSTextAttachment()
        foreign.image = NSImage(size: NSSize(width: 16, height: 16))
        let unsafe = NSMutableAttributedString(attributedString: NSAttributedString(attachment: foreign))
        unsafe.append(NSAttributedString(string: "\u{FFFC} external"))
        unsafe.addAttribute(NSAttributedString.Key("MinisCanvas.statusIconOriginal"), value: "✅",
            range: NSRange(location: 0, length: unsafe.length))
        #expect(!ChatTranscriptStatusIconProjection.copyText(unsafe).contains("✅"))
        let generic = ReadOnlyAttributedTextView(attributedString: unsafe).attributedString
        #expect(!generic.string.contains("\u{FFFC}"))
        #expect(generic.string.contains("[附件内容已隐藏]"))
        #expect(attachmentRanges(generic).isEmpty)
        let projected = ChatTranscriptFormatter.formattedDocument([
            ChatMessageUI(role: .assistant, content: "⚠️ synthetic")
        ]).attributedString
        #expect(attachmentRanges(projected).count == 1)
        let mixed = NSMutableAttributedString(attributedString: projected)
        mixed.append(unsafe)
        // Re-enter through the public, untrusted attributed-string boundary.
        // No test can construct the product's private final attachment class.
        for safe in [ReadOnlyAttributedTextView.sanitized(mixed),
                     ReadOnlyAttributedTextView(attributedString: mixed).attributedString,
                     ChatTranscriptStatusIconProjection.prepare(mixed)] {
            #expect(!safe.string.contains("\u{FFFC}"))
            #expect(safe.string.contains("[附件内容已隐藏]"))
            #expect(attachmentRanges(safe).isEmpty)
        }
    }

    @Test func fullAppendAndTailReprojectOriginalChunksThroughNativeStorage() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let cache = ChatTranscriptDocumentCache()
        let sessionID = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "history")
        var tail = ChatMessageUI(role: .assistant, content: "⚠", isStreaming: true)
        func render(_ messages: [ChatMessageUI]) -> ChatTranscriptFormattedDocument {
            cache.render(sessionID: sessionID, messages: messages, baseSize: 13, redactor: redactor)
        }
        let initial = render([history])
        let component = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let coordinator = component.makeCoordinator()
        let scroll = component.makeNSView(coordinator: coordinator)
        defer { ReadOnlyAttributedTextView.dismantleNSView(scroll, coordinator: coordinator) }
        let text = try #require(scroll.documentView as? NSTextView)
        let generation = cache.update.generation
        let chunks: [(body: String, expectedIconCount: Int)] = [
            ("⚠", 1), ("⚠\u{FE0F} warning", 1), ("⚠x", 1), ("prefix ⚠️ middle", 1), ("prefix plain end", 0)
        ]
        for chunk in chunks {
            let body = chunk.body
            tail.content = body
            let messages = [history, tail]
            let document = render(messages)
            ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
                .updateNSView(scroll, coordinator: coordinator)
            let expected = ChatTranscriptFormatter.formattedMessage(history, baseSize: 13, redactor: nil).string
                + "\n\n" + ChatTranscriptFormatter.formattedMessage(tail, baseSize: 13, redactor: nil).string
            #expect(text.string == document.attributedString.string)
            #expect(ChatTranscriptStatusIconProjection.copyText(text.attributedString()) == expected)
            #expect(cache.update.generation == generation)
            #expect(tail.content == body)
            #expect(ChatTranscriptFormatter.persistedEntries([tail]).first?.text == body)
            #expect(attachmentRanges(text.attributedString()).count == chunk.expectedIconCount)
            if chunk.expectedIconCount == 1 {
                #expect(!text.string.contains("\u{FE0F}"))
            } else {
                #expect(attachmentRanges(text.attributedString()).isEmpty)
                #expect(text.string.contains("prefix plain end"))
            }
            if body == "prefix ⚠️ middle" {
                #expect(text.string.contains("prefix \u{FFFC} middle"))
                #expect(ChatTranscriptStatusIconProjection.copyText(text.attributedString()).contains("prefix ⚠️ middle"))
            }
            #expect(document.messageStartLocations.count == 2)
            let second = document.messageStartLocations[1]
            #expect((document.attributedString.string as NSString).substring(from: second).hasPrefix("助手\n"))
        }
    }

    @Test func inlineAndCodeOnlyEmojiDoNotChangeRawAccessibilityBody() {
        for body in ["```text\n⚠ block\n```", "`⚠ inline` 与普通正文"] {
            let message = ChatMessageUI(role: .assistant, content: body)
            #expect(ChatTranscriptFormatter.accessibilityText([message]) == "助手：" + body)
        }
    }

    @Test func inlineClosedStatusUsesAccessibilityLabelsWithoutLosingBody() {
        let body = "**说明** 中间 ✅ 保留原始 Markdown"
        let message = ChatMessageUI(role: .assistant, content: body)
        let accessible = ChatTranscriptFormatter.accessibilityText([message])
        #expect(accessible.hasPrefix("助手："))
        #expect(accessible.contains("说明") && accessible.contains("中间"))
        #expect(accessible.contains("成功") && accessible.contains("保留原始 Markdown"))
        #expect(!accessible.contains("✅") && !accessible.contains("\u{FFFC}"))
        #expect(message.content == body)
    }

    @Test func inlineIconsDoNotIncreaseNativeMultilineLineHeight() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let body = String(repeating: "正文已完成✅继续，⚠️注意并保持连续的多行阅读。", count: 35)
        let document = ChatTranscriptFormatter.formattedDocument([ChatMessageUI(role: .assistant, content: body)])
        let control = NSMutableAttributedString(attributedString: document.attributedString)
        let ranges = attachmentRanges(control)
        try #require(ranges.count == 70)
        // Native font-glyph control: replace only the display object with a
        // normal CJK glyph, keeping the same real font and paragraph attributes.
        for range in ranges.reversed() {
            control.removeAttribute(.attachment, range: range)
            control.replaceCharacters(in: range, with: "字")
        }
        func lineFacts(_ attributed: NSAttributedString, width: CGFloat, phase: String) throws -> [CGFloat] {
            let component = ReadOnlyAttributedTextView(transcriptDocument:
                ChatTranscriptFormattedDocument(attributedString: attributed, messageStartLocations: [0]),
                update: ChatTranscriptStorageUpdate(revision: 1, generation: 1, replacementStart: nil, replacement: nil))
            let coordinator = component.makeCoordinator()
            let scroll = component.makeNSView(coordinator: coordinator)
            defer { ReadOnlyAttributedTextView.dismantleNSView(scroll, coordinator: coordinator) }
            _ = try #require(component.sizeThatFits(ProposedViewSize(width: width, height: nil),
                nsView: scroll, coordinator: coordinator))
            let text = try #require(scroll.documentView as? NSTextView)
            let container = try #require(text.textContainer)
            let manager = try #require(text.layoutManager)
            manager.ensureLayout(for: container)
            var heights: [CGFloat] = []
            let bodyGlyphs = manager.glyphRange(forCharacterRange:
                NSRange(location: 3, length: attributed.length - 3), actualCharacterRange: nil)
            manager.enumerateLineFragments(forGlyphRange: bodyGlyphs) {
                rect, _, _, _, _ in heights.append(rect.height)
            }
            print("GOAL22_INLINE_ICON_LINE_HEIGHT phase=\(phase) width=\(width) lines=\(heights.count) maxLineHeight=\(heights.max() ?? 0) usedRect=\(manager.usedRect(for: container))")
            try #require(heights.count > 2)
            return heights
        }
        for width in [CGFloat(500), 760] {
            let native = try lineFacts(document.attributedString, width: width, phase: "icons")
            let ordinary = try lineFacts(control, width: width, phase: "font-glyph-control")
            // Exclude the paragraph's first/last fragments so header or
            // paragraph spacing cannot mask a taller inline-icon text row.
            let ordinaryMaximum = try #require(ordinary.dropFirst().dropLast().max())
            try #require(!native.dropFirst().dropLast().isEmpty)
            #expect(native.dropFirst().dropLast().allSatisfy { $0 <= ordinaryMaximum })
        }
        #expect(ChatTranscriptStatusIconProjection.copyText(document.attributedString)
            == ChatTranscriptFormatter.formattedMessage(ChatMessageUI(role: .assistant, content: body), baseSize: 13, redactor: nil).string)
    }

    @Test func factoryConfigurationAndTwoWidthLongTranscriptGeometryStayEquivalent() throws {
        let legacyScroll = NSTextView.scrollableTextView()
        let legacyText = try #require(legacyScroll.documentView as? NSTextView)
        let legacyIsTextKit2 = legacyText.textLayoutManager != nil
        let body = (0..<120).map { "合成长转录第\($0)段，保持原生阅读宽度、换行和高度。" }.joined(separator: "\n\n")
        let document = ChatTranscriptFormatter.formattedDocument([ChatMessageUI(role: .assistant, content: body)])
        let component = ReadOnlyAttributedTextView(transcriptDocument: document,
            update: ChatTranscriptStorageUpdate(revision: 1, generation: 1, replacementStart: nil, replacement: nil))
        let coordinator = component.makeCoordinator()
        let currentScroll = component.makeNSView(coordinator: coordinator)
        defer { ReadOnlyAttributedTextView.dismantleNSView(currentScroll, coordinator: coordinator) }
        let currentText = try #require(currentScroll.documentView as? NSTextView)
        let currentIsTextKit2 = currentText.textLayoutManager != nil
        func dump(_ label: String, scroll: NSScrollView, text: NSTextView, isTextKit2: Bool) {
            let container = text.textContainer
            print("GOAL22_FACTORY_CONFIG label=\(label) tk2=\(isTextKit2) autoresizing=\(text.autoresizingMask.rawValue) frame=\(text.frame) min=\(text.minSize) max=\(text.maxSize) horizontal=\(text.isHorizontallyResizable) vertical=\(text.isVerticallyResizable) containerSize=\(String(describing: container?.containerSize)) tracksWidth=\(String(describing: container?.widthTracksTextView)) tracksHeight=\(String(describing: container?.heightTracksTextView)) verticalScroller=\(scroll.hasVerticalScroller) horizontalScroller=\(scroll.hasHorizontalScroller) autohides=\(scroll.autohidesScrollers) border=\(scroll.borderType.rawValue) drawsBackground=\(scroll.drawsBackground) contentInsets=\(scroll.contentInsets)")
        }
        dump("factory-initial", scroll: legacyScroll, text: legacyText, isTextKit2: legacyIsTextKit2)
        // Apply the pre-change production read-only configuration to the old
        // factory. Keep its own frame/autoresizing/container initial state.
        legacyText.isEditable = false
        legacyText.isSelectable = true
        legacyText.isHorizontallyResizable = false
        legacyText.isVerticallyResizable = true
        legacyText.minSize = .zero
        legacyText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        legacyText.drawsBackground = false
        legacyText.textContainerInset = .zero
        legacyText.textContainer?.lineFragmentPadding = 0
        legacyText.textContainer?.widthTracksTextView = false
        legacyText.textContainer?.lineBreakMode = ReadOnlyAttributedTextView.transcriptLineBreakMode
        legacyText.isRichText = true
        legacyText.usesAdaptiveColorMappingForDarkAppearance = false
        legacyText.textStorage?.setAttributedString(document.attributedString)
        legacyScroll.drawsBackground = false
        legacyScroll.hasVerticalScroller = false
        legacyScroll.hasHorizontalScroller = false
        legacyScroll.autohidesScrollers = true
        dump("factory-configured", scroll: legacyScroll, text: legacyText, isTextKit2: legacyIsTextKit2)
        dump("subclass-configured", scroll: currentScroll, text: currentText, isTextKit2: currentIsTextKit2)
        #expect(currentIsTextKit2 == legacyIsTextKit2)
        #expect(currentText.autoresizingMask == legacyText.autoresizingMask)
        #expect(currentText.frame == legacyText.frame)
        #expect(currentText.minSize == legacyText.minSize && currentText.maxSize == legacyText.maxSize)
        #expect(currentText.isHorizontallyResizable == legacyText.isHorizontallyResizable)
        #expect(currentText.isVerticallyResizable == legacyText.isVerticallyResizable)
        #expect(currentText.textContainer?.containerSize == legacyText.textContainer?.containerSize)
        #expect(currentText.textContainer?.widthTracksTextView == legacyText.textContainer?.widthTracksTextView)
        #expect(currentText.textContainer?.heightTracksTextView == legacyText.textContainer?.heightTracksTextView)
        #expect(currentScroll.hasVerticalScroller == legacyScroll.hasVerticalScroller)
        #expect(currentScroll.hasHorizontalScroller == legacyScroll.hasHorizontalScroller)
        #expect(currentScroll.autohidesScrollers == legacyScroll.autohidesScrollers)
        #expect(currentScroll.borderType == legacyScroll.borderType)
        #expect(currentScroll.drawsBackground == legacyScroll.drawsBackground)
        #expect(currentScroll.contentInsets.top == legacyScroll.contentInsets.top)
        #expect(currentScroll.contentInsets.left == legacyScroll.contentInsets.left)
        #expect(currentScroll.contentInsets.bottom == legacyScroll.contentInsets.bottom)
        #expect(currentScroll.contentInsets.right == legacyScroll.contentInsets.right)
        func measure(_ scroll: NSScrollView, text: NSTextView, width: CGFloat, label: String) throws -> NSRect {
            let lease = NativeTestHostLifecycle.begin("Goal22FactoryGeometry", requestActivation: false)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            NativeTestHostLifecycle.bind(lease, to: window)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer {
                window.contentView = nil
                window.close()
                NativeTestHostLifecycle.end(window)
            }
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            text.frame = scroll.bounds
            let container = try #require(text.textContainer)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            window.layoutIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            let manager = try #require(text.layoutManager)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            print("GOAL22_FACTORY_GEOMETRY label=\(label) width=\(width) usedRect=\(used) height=\(ReadOnlyAttributedTextView.measuredContentHeight(usedRect: used, inset: text.textContainerInset))")
            #expect(used.height > 0 && used.width > 0)
            return used
        }
        for width in [CGFloat(500), 900] {
            let before = try measure(legacyScroll, text: legacyText, width: width, label: "factory")
            let after = try measure(currentScroll, text: currentText, width: width, label: "subclass")
            #expect(abs(before.minX - after.minX) <= 0.5 && abs(before.minY - after.minY) <= 0.5)
            #expect(abs(before.width - after.width) <= 0.5 && abs(before.height - after.height) <= 0.5)
            #expect(ReadOnlyAttributedTextView.measuredContentHeight(usedRect: before, inset: legacyText.textContainerInset)
                == ReadOnlyAttributedTextView.measuredContentHeight(usedRect: after, inset: currentText.textContainerInset))
        }
        withExtendedLifetime(coordinator) {}
    }

    @Test func nativeSelectionAndSelectAllRestoreEmojiWithoutRTFAttachment() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let factory = NSTextView.scrollableTextView()
        let factoryText = try #require(factory.documentView as? NSTextView)
        let factoryIsTextKit2 = factoryText.textLayoutManager != nil
        let message = ChatMessageUI(role: .assistant, content:
            "⚠️ synthetic warning\n\n正文 ✅ 行中保留\n\n测试对话已成功创建。✅\n\n⚠️注意\n\n- ✅ 完成\n\n已完成✅继续")
        let document = ChatTranscriptFormatter.formattedDocument([message])
        let original = ChatTranscriptFormatter.formattedMessage(message, baseSize: 13, redactor: nil).string
        let component = ReadOnlyAttributedTextView(transcriptDocument: document,
            update: ChatTranscriptStorageUpdate(revision: 1, generation: 1, replacementStart: nil, replacement: nil))
        let coordinator = component.makeCoordinator()
        let scroll = component.makeNSView(coordinator: coordinator)
        let text = try #require(scroll.documentView as? NSTextView)
        // Both reads precede any explicit layoutManager getter in this case.
        #expect((text.textLayoutManager != nil) == factoryIsTextKit2)
        #expect(text.usesFindBar == factoryText.usesFindBar)
        #expect(text.accessibilityRole() == factoryText.accessibilityRole())
        let lease = NativeTestHostLifecycle.begin("Goal22StatusCopy", requestActivation: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer {
            window.makeFirstResponder(nil)
            ReadOnlyAttributedTextView.dismantleNSView(scroll, coordinator: coordinator)
            window.contentView = nil
            window.close()
            NativeTestHostLifecycle.end(window)
            withExtendedLifetime(coordinator) {}
        }
        try #require(window.makeFirstResponder(text))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let icons = attachmentRanges(text.attributedString())
        let originals = ["⚠️", "✅", "✅", "⚠️", "✅", "✅"]
        try #require(icons.count == originals.count)
        let legacyFlavor = NSPasteboard.PasteboardType(rawValue: "NSStringPboardType")
        for (icon, originalEmoji) in zip(icons, originals) {
            text.setSelectedRange(icon)
            #expect(text.writablePasteboardTypes == [.string])
            #expect(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
            #expect(pasteboard.string(forType: .string) == originalEmoji)
            let legacyCopy = pasteboard.string(forType: legacyFlavor)
            if let legacyCopy { #expect(legacyCopy == originalEmoji) }
            print("GOAL22_STATUS_COPY_FLAVORS selection=icon modernMatches=\(pasteboard.string(forType: .string) == originalEmoji) legacyPresent=\(legacyCopy != nil) legacyMatches=\(legacyCopy == originalEmoji)")
        }
        text.selectAll(nil)
        #expect(text.selectedRange() == NSRange(location: 0, length: text.string.utf16.count))
        #expect(text.writablePasteboardTypes == [.string])
        #expect(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == original)
        let allLegacyCopy = pasteboard.string(forType: legacyFlavor)
        if let allLegacyCopy { #expect(allLegacyCopy == original) }
        print("GOAL22_STATUS_COPY_FLAVORS selection=all modernMatches=\(pasteboard.string(forType: .string) == original) legacyPresent=\(allLegacyCopy != nil) legacyMatches=\(allLegacyCopy == original)")
        #expect(pasteboard.string(forType: .string)?.contains("\u{FFFC}") == false)
        #expect(pasteboard.data(forType: .rtfd) == nil)
        if let rtf = pasteboard.data(forType: .rtf) {
            let copied = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            #expect(attachmentRanges(copied).isEmpty)
            #expect(!copied.string.contains("\u{FFFC}"))
            #expect(copied.string == original)
        }
    }
}
