import Testing
import Foundation
import AppKit
import CoreText
import MinisCore
@testable import MinisCanvasApp

@Suite("UX-02 对话正文阅读体验", .serialized)
@MainActor
struct UX02ChatReadingTests {
    @Test("dark transcript keeps its resolved foreground through the native text consumer")
    func darkTranscriptDoesNotInvertResolvedForeground955() throws {
        let message = ChatMessageUI(role: .assistant, content: "欢迎使用 MinisCanvas！\n\n**快捷键**")
        let document = ChatTranscriptFormatter.formattedDocument(
            [message], palette: .readableDark
        )
        let update = ChatTranscriptStorageUpdate(
            revision: 1, generation: 1, replacementStart: nil, replacement: nil
        )
        let transcript = ReadOnlyAttributedTextView(transcriptDocument: document, update: update)
        let scrollView = transcript.makeNSView(coordinator: transcript.makeCoordinator())
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.appearance = NSAppearance(named: .darkAqua)
        #expect(textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(!textView.usesAdaptiveColorMappingForDarkAppearance)

        let location = (textView.string as NSString).range(of: "欢迎使用").location
        guard location != NSNotFound else {
            Issue.record("The native transcript did not contain the welcome body")
            return
        }
        let color = try #require(textView.textStorage?.attribute(
            .foregroundColor, at: location, effectiveRange: nil
        ) as? NSColor)
        let rgb = try #require(color.usingColorSpace(.sRGB))
        #expect(abs(Double(rgb.redComponent) - Aj38Palette.readableDark.textPrimary.r) < 0.000001)
        #expect(abs(Double(rgb.greenComponent) - Aj38Palette.readableDark.textPrimary.g) < 0.000001)
        #expect(abs(Double(rgb.blueComponent) - Aj38Palette.readableDark.textPrimary.b) < 0.000001)

        let ordinary = ReadOnlyAttributedTextView(attributedString: document.attributedString)
        let ordinaryView = ordinary.makeNSView(coordinator: ordinary.makeCoordinator())
        #expect((ordinaryView.documentView as? NSTextView)?.usesAdaptiveColorMappingForDarkAppearance == true)
    }

    @Test("theme 866 rebuilds full transcript/body/code/list colors from the current palette")
    func paletteSwitchRecolorsAllMarkdownRuns866() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let messages = [ChatMessageUI(role: .assistant,
            content: "- 866 bullet\n\n```swift\nlet theme866 = 1\n```\n\n866 body")]
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let palettes = [Aj38Palette.readableDark, .readableLight, .readableDark]
        let ambient = try #require(NSAppearance(named: .darkAqua))
        var rendered: [NSAttributedString] = []
        var generations: [UInt64] = []
        var replacementStarts: [Int?] = []
        var formattedCounts: [Int] = []
        // A local drawing appearance is a negative control, not a system switch:
        // explicit light palette must win even while AppKit's ambient is dark.
        ambient.performAsCurrentDrawingAppearance {
            for palette in palettes {
                let document = cache.render(sessionID: session, messages: messages,
                    baseSize: 13, redactor: redactor, palette: palette)
                rendered.append(NSAttributedString(attributedString: document.attributedString))
                generations.append(cache.update.generation)
                replacementStarts.append(cache.update.replacementStart)
                formattedCounts.append(cache.lastFormattedMessageCount)
            }
        }
        #expect(rendered.count == 3)
        #expect(generations[1] == generations[0] + 1)
        #expect(generations[2] == generations[1] + 1)
        #expect(replacementStarts.allSatisfy { $0 == nil })
        #expect(formattedCounts == [1, 1, 1])
        #expect(rendered[0].string == rendered[1].string)
        #expect(rendered[1].string == rendered[2].string)
        for (document, palette) in zip(rendered, palettes) {
            let text = document.string as NSString
            for (marker, alpha) in [("866 body", 1.0), ("let theme866", 1.0), ("swift", 0.75), ("•", 0.75)] {
                let range = text.range(of: marker)
                #expect(range.location != NSNotFound)
                guard range.location != NSNotFound else { continue }
                let color = try #require(document.attribute(.foregroundColor,
                    at: range.location, effectiveRange: nil) as? NSColor)
                let rgb = try #require(color.usingColorSpace(.sRGB))
                #expect(abs(Double(rgb.redComponent) - palette.textPrimary.r) < 0.000001)
                #expect(abs(Double(rgb.greenComponent) - palette.textPrimary.g) < 0.000001)
                #expect(abs(Double(rgb.blueComponent) - palette.textPrimary.b) < 0.000001)
                #expect(abs(Double(rgb.alphaComponent) - alpha) < 0.000001)
            }
        }
        let stable = cache.render(sessionID: session, messages: messages,
            baseSize: 13, redactor: redactor, palette: palettes[2])
        #expect(cache.lastFormattedMessageCount == 0)
        #expect(cache.update.generation == generations[2])
        #expect(stable.attributedString.isEqual(to: rendered[2]))
    }

    @Test func toolResultUsesExplicitLabelAlignmentAndNoMetadataLeak() {
        let call = LLMToolCall(
            id: "call-ux02-private",
            name: "shell_execute",
            rawArguments: "{\"command\":\"secret-command\"}",
            arguments: ["command": "secret-command"]
        )
        let message = ChatMessageUI(
            role: .tool,
            content: "工具执行完成",
            toolCallID: call.id,
            toolCalls: [call]
        )

        let plain = ChatTranscriptFormatter.plainText([message])
        let attributed = ChatTranscriptFormatter.attributedString([message])
        let accessible = ChatTranscriptFormatter.accessibilityText([message])
        let range = (attributed.string as NSString).range(of: "工具执行完成")
        let style = attributed.attribute(
            .paragraphStyle,
            at: range.location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        #expect(plain == "【工具】\n工具执行完成")
        #expect(accessible == "工具：工具执行完成")
        #expect(style?.alignment == .left)
        #expect(!plain.contains("call-ux02-private"))
        #expect(!plain.contains("shell_execute"))
        #expect(!plain.contains("secret-command"))
        #expect(!accessible.contains("call-ux02-private"))
        #expect(!attributed.string.contains("call-ux02-private"))
    }

    @Test func longMixedTranscriptUsesOneReadableColumnForEveryRole() {
        let messages = [
            ChatMessageUI(role: .user, content: Self.longMixedContent),
            ChatMessageUI(role: .assistant, content: Self.longMixedContent)
        ]

        let attributed = ChatTranscriptFormatter.attributedString(messages)
        let userRange = (attributed.string as NSString).range(of: "用户请求：")
        let assistantRange = (attributed.string as NSString).range(
            of: "用户请求：",
            options: [],
            range: NSRange(location: userRange.upperBound, length: attributed.length - userRange.upperBound)
        )
        let userStyle = attributed.attribute(
            NSAttributedString.Key.paragraphStyle,
            at: userRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let assistantStyle = attributed.attribute(
            NSAttributedString.Key.paragraphStyle,
            at: assistantRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        #expect(attributed.string.contains("中文长段落"))
        #expect(attributed.string.contains("readable content"))
        #expect(attributed.string.contains("let result = items.map"))
        #expect(attributed.string.contains("工具输出："))
        #expect(attributed.string.contains("列名"))
        #expect(userStyle?.firstLineHeadIndent == 28)
        #expect(userStyle?.headIndent == 28)
        #expect(userStyle?.tailIndent == -28)
        #expect(assistantStyle?.firstLineHeadIndent == 28)
        #expect(assistantStyle?.headIndent == 28)
        #expect(assistantStyle?.tailIndent == -28)
        #expect(userStyle?.firstLineHeadIndent == assistantStyle?.firstLineHeadIndent)
        #expect(userStyle?.headIndent == assistantStyle?.headIndent)
        #expect(userStyle?.tailIndent == assistantStyle?.tailIndent)
        #expect(userStyle?.paragraphSpacing == 10)
        #expect(userStyle?.lineSpacing == 2)
    }

    @Test func fencedCodeUsesOneBackgroundAcrossMultipleLines() throws {
        let content = "Before\n\n```swift\nlet first = 1\nlet second = 2\n```\n\nAfter"
        let messages = [ChatMessageUI(role: .assistant, content: content)]
        let rendered = ChatTranscriptFormatter.attributedString(messages)
        func blocks(at text: String) throws -> [NSTextBlock] {
            let range = (rendered.string as NSString).range(of: text)
            try #require(range.location != NSNotFound)
            let style = try #require(rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            return style.textBlocks
        }
        let prose = try blocks(at: "Before")
        let first = try blocks(at: "let first = 1")
        let second = try blocks(at: "let second = 2")
        #expect(first.count > prose.count)
        #expect(second.count == first.count)
        let firstCodeBlock = try #require(first.last)
        let secondCodeBlock = try #require(second.last)
        #expect(firstCodeBlock === secondCodeBlock)
        #expect(firstCodeBlock.backgroundColor != nil)
        #expect(try blocks(at: "swift").count == prose.count)
        #expect(ChatTranscriptFormatter.plainText(messages) == "【助手】\n\(content)")
    }

    @Test func longMixedTranscriptRetainsMarkdownStylingAndRawCopySemantics() {
        let content = Self.longMixedContent
        let messages = [ChatMessageUI(role: .assistant, content: content)]
        let attributed = ChatTranscriptFormatter.attributedString(messages)

        #expect(attributed.string.contains("标题：阅读上下文"))
        #expect(attributed.string.contains("let result = items.map"))
        #expect(attributed.string.contains("工具输出："))
        #expect(attributed.string.contains("列名"))
        #expect(attributed.string.contains("第一行结果"))

        var hasHeadingFont = false
        attributed.enumerateAttribute(NSAttributedString.Key.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let font = value as? NSFont, font.pointSize > 13 {
                hasHeadingFont = true
            }
        }
        #expect(hasHeadingFont)
        let bodyRange = (attributed.string as NSString).range(of: "let result = items.map")
        let bodyStyle = attributed.attribute(.paragraphStyle, at: bodyRange.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(bodyStyle?.textBlocks.first?.backgroundColor != nil)
        #expect((bodyStyle?.textBlocks.count ?? 0) > 1)
        #expect(bodyStyle?.textBlocks.last?.backgroundColor != nil)
        #expect(ChatTranscriptFormatter.plainText(messages) == "【助手】\n\(content)")
    }

    @Test func redactionStillAppliesToReadableTranscriptAndCopy() {
        let secret = "sk-ux02-reading-secret-9f3a"
        let content = "工具输出：请求已完成，凭据 \(secret) 不应进入正文或复制内容。"
        let messages = [ChatMessageUI(role: .assistant, content: content)]
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        let plain = ChatTranscriptFormatter.plainText(messages, redactor: redactor)
        let attributed = ChatTranscriptFormatter.attributedString(messages, redactor: redactor)
        let accessible = ChatTranscriptFormatter.accessibilityText(messages, redactor: redactor)

        #expect(!plain.contains(secret))
        #expect(!attributed.string.contains(secret))
        #expect(!accessible.contains(secret))
        #expect(plain.contains("工具输出："))
        #expect(attributed.string.contains("凭据"))
    }

    @Test func streamingUpdateKeepsSelectionAndCopyBoundariesObservable() {
        let first = ChatTranscriptFormatter.attributedString([
            ChatMessageUI(role: .assistant, content: "第一段中文", isStreaming: true)
        ])
        let streamed = ChatTranscriptFormatter.attributedString([
            ChatMessageUI(
                role: .assistant,
                content: "第一段中文\n\n```swift\nlet result = items.map { $0.value }",
                isStreaming: true
            )
        ])

        #expect(ReadOnlyAttributedTextView.shouldReplaceTextStorage(current: first, replacement: streamed))
        let preserved = ReadOnlyAttributedTextView.preservedSelectionRanges(
            [NSValue(range: NSRange(location: 2, length: 4))],
            contentLength: streamed.length
        )
        #expect(preserved.map(\.rangeValue) == [NSRange(location: 2, length: 4)])
        #expect(ChatTranscriptFormatter.plainText([
            ChatMessageUI(role: .assistant, content: "第一段中文\n\n第二段英文 readable content")
        ]).contains("第二段英文 readable content"))
    }

    @Test func transcriptTailPatchPreservesHistoryAndMatchesFullSafeRender() {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let oldSecret = "sk-history-private-123456"
        let liveSecret = "sk-stream-private-abcdef"
        let redactor = ChatTranscriptRedactor(secretValues: [oldSecret, liveSecret])
        let history = ChatMessageUI(role: .user, content: "历史凭据 \(oldSecret) " + String(repeating: "旧正文", count: 2_000))
        let replyID = UUID()
        let first = ChatMessageUI(id: replyID, role: .assistant, content: "", isStreaming: true)
        let firstDocument = cache.render(sessionID: session, messages: [history, first], baseSize: 13, redactor: redactor)
        let oldStorage = Self.consumerStorage(firstDocument.attributedString)
        oldStorage.ensureAttributesAreFixed(in: NSRange(location: 0, length: oldStorage.length))
        let historyLocation = firstDocument.messageStartLocations[1]
        let historyRange = NSRange(location: 0, length: historyLocation)
        // The cache owns mutable backing storage. Capture a value before the
        // next render, including the same historical block identities.
        let cachePrefix = firstDocument.attributedString.attributedSubstring(from: historyRange)
        let storagePrefix = oldStorage.attributedSubstring(from: historyRange)
        let generation = cache.update.generation

        let streamed = ChatMessageUI(
            id: replyID, role: .assistant,
            content: "第一段\n\n凭据 \(liveSecret)\n\n**后续**", isStreaming: true
        )
        let updated = cache.render(sessionID: session, messages: [history, streamed], baseSize: 13, redactor: redactor)
        let change = cache.update
        #expect(change.replacementStart == historyLocation)
        #expect(updated.messageStartLocations[1] == historyLocation)
        #expect(change.generation == generation)
        #expect(updated.attributedString.attributedSubstring(from: historyRange).isEqual(to: cachePrefix))
        #expect(!updated.attributedString.string.contains(oldSecret))
        #expect(!updated.attributedString.string.contains(liveSecret))
        #expect(!cache.accessibilityText.contains(oldSecret))
        #expect(!cache.accessibilityText.contains(liveSecret))

        oldStorage.replaceCharacters(
            in: NSRange(location: historyLocation, length: oldStorage.length - historyLocation),
            with: change.replacement!
        )
        let full = ReadOnlyAttributedTextView.sanitized(
            ChatTranscriptFormatter.formattedDocument(
                [history, streamed], baseSize: 13, redactor: redactor
            ).attributedString
        )
        #expect(oldStorage.attributedSubstring(from: historyRange).isEqual(to: storagePrefix))
        // NSTextStorage fixes fonts for the actual glyphs (e.g. Chinese fallback)
        // and paragraph ranges. Compare both sides at the same TextKit stage.
        let fullStorage = Self.consumerStorage(full)
        #expect(Self.renderingDifference(oldStorage, fullStorage) == nil)
        #expect(Self.renderingDifference(updated.attributedString, full) == nil)
        #expect(cache.accessibilityText == ChatTranscriptFormatter.accessibilityText(
            [history, streamed], redactor: redactor
        ))

        let appended = ChatMessageUI(role: .tool, content: "工具已完成")
        let oldLength = updated.attributedString.length
        let withNewMessage = cache.render(
            sessionID: session, messages: [history, streamed, appended],
            baseSize: 13, redactor: redactor
        )
        #expect(cache.update.replacementStart == oldLength)
        #expect(withNewMessage.messageStartLocations[2] == oldLength + 2)
        #expect(withNewMessage.attributedString.string.contains("工具已完成"))
        let appendedFull = ReadOnlyAttributedTextView.sanitized(
            ChatTranscriptFormatter.attributedString([history, streamed, appended], redactor: redactor)
        )
        #expect(Self.renderingDifference(withNewMessage.attributedString, appendedFull) == nil)
    }

    @Test func transcriptRenderComparisonRejectsStylingSafetyAndBlockTopologyChanges() {
        let message = ChatMessageUI(role: .assistant, content: "第一段中文\n\n第二段 readable content")
        let baseline = ReadOnlyAttributedTextView.sanitized(ChatTranscriptFormatter.attributedString([message]))
        let independent = ReadOnlyAttributedTextView.sanitized(ChatTranscriptFormatter.attributedString([message]))
        #expect(Self.renderingDifference(baseline, independent) == nil)

        let bodyAt = (baseline.string as NSString).range(of: "第一段").location
        let bodyRange = NSRange(location: bodyAt, length: 1)
        let originalStyle = baseline.attribute(.paragraphStyle, at: bodyAt, effectiveRange: nil) as! NSParagraphStyle
        let originalBlock = originalStyle.textBlocks[0]

        let wrongText = NSMutableAttributedString(attributedString: baseline)
        wrongText.replaceCharacters(in: bodyRange, with: "错")
        #expect(Self.renderingDifference(baseline, wrongText) != nil)
        let wrongFont = NSMutableAttributedString(attributedString: baseline)
        wrongFont.addAttribute(.font, value: NSFont.systemFont(ofSize: 24), range: bodyRange)
        #expect(Self.renderingDifference(baseline, wrongFont) != nil)
        let wrongColor = NSMutableAttributedString(attributedString: baseline)
        wrongColor.addAttribute(.foregroundColor, value: NSColor.systemRed, range: bodyRange)
        #expect(Self.renderingDifference(baseline, wrongColor) != nil)
        let unsafeLink = NSMutableAttributedString(attributedString: baseline)
        unsafeLink.addAttribute(.link, value: "https://example.invalid/should-not-be-executable", range: bodyRange)
        #expect(Self.renderingDifference(baseline, unsafeLink) != nil)

        let wrongParagraph = NSMutableAttributedString(attributedString: baseline)
        let spacing = originalStyle.mutableCopy() as! NSMutableParagraphStyle
        spacing.paragraphSpacing += 1
        wrongParagraph.addAttribute(.paragraphStyle, value: spacing, range: bodyRange)
        #expect(Self.renderingDifference(baseline, wrongParagraph) != nil)

        // Copy before mutation: paragraph-style copies retain the block objects.
        let wrongBackground = NSMutableAttributedString(attributedString: baseline)
        let backgroundStyle = originalStyle.mutableCopy() as! NSMutableParagraphStyle
        let backgroundBlock = originalBlock.copy() as! NSTextBlock
        backgroundBlock.backgroundColor = .systemRed
        backgroundStyle.textBlocks = [backgroundBlock]
        wrongBackground.addAttribute(.paragraphStyle, value: backgroundStyle, range: bodyRange)
        #expect(Self.renderingDifference(baseline, wrongBackground) != nil)
        #expect(Self.renderingDifference(
            baseline.attributedSubstring(from: bodyRange), wrongBackground.attributedSubstring(from: bodyRange)
        ) != nil)

        let wrongGeometry = NSMutableAttributedString(attributedString: baseline)
        let geometryStyle = originalStyle.mutableCopy() as! NSMutableParagraphStyle
        let geometryBlock = originalBlock.copy() as! NSTextBlock
        geometryBlock.setContentWidth(originalBlock.contentWidth + 1, type: originalBlock.contentWidthValueType)
        geometryStyle.textBlocks = [geometryBlock]
        wrongGeometry.addAttribute(.paragraphStyle, value: geometryStyle, range: bodyRange)
        #expect(Self.renderingDifference(baseline, wrongGeometry) != nil)
        #expect(Self.renderingDifference(
            baseline.attributedSubstring(from: bodyRange), wrongGeometry.attributedSubstring(from: bodyRange)
        ) != nil)

        let wrongSharing = NSMutableAttributedString(attributedString: baseline)
        let sharingStyle = originalStyle.mutableCopy() as! NSMutableParagraphStyle
        sharingStyle.textBlocks = [originalBlock.copy() as! NSTextBlock]
        wrongSharing.addAttribute(.paragraphStyle, value: sharingStyle, range: bodyRange)
        #expect(Self.renderingDifference(baseline, wrongSharing) != nil)
        // Negative controls must not mutate the baseline's shared surface.
        #expect(Self.renderingDifference(baseline, independent) == nil)
    }

    @Test func transcriptTableComparisonChecksCellTableStylesAndSharing() throws {
        let message = ChatMessageUI(role: .assistant, content:
            "| A | B |\n| --- | --- |\n| C | D |\n\n两张独立表\n\n| E | F |\n| --- | --- |\n| G | H |")
        func document() -> NSMutableAttributedString {
            NSMutableAttributedString(attributedString: ReadOnlyAttributedTextView.sanitized(
                ChatTranscriptFormatter.attributedString([message])))
        }
        let baseline = document()
        #expect(Self.renderingDifference(baseline, baseline) == nil)
        #expect(Self.renderingDifference(baseline, document()) == nil)

        // Mutate an independently rendered object, never baseline's shared table.
        let tableMutations: [(NSTextTable) -> Void] = [
            { $0.numberOfColumns += 1 },
            { $0.layoutAlgorithm = .automaticLayoutAlgorithm },
            { $0.collapsesBorders.toggle() },
            { $0.hidesEmptyCells.toggle() },
            { $0.backgroundColor = .systemRed },
            { $0.setContentWidth($0.contentWidth + 1, type: $0.contentWidthValueType) },
            { $0.setWidth(17, type: .absoluteValueType, for: .padding, edge: .minX) }
        ]
        for mutate in tableMutations {
            let changed = document()
            let first = try #require(Self.tableCellSites(changed).first)
            mutate(first.cell.table)
            #expect(Self.renderingDifference(baseline, changed) != nil)
        }

        for component in 0..<4 {
            let changed = document()
            let first = try #require(Self.tableCellSites(changed).first)
            let cell = first.cell
            let replacement = Self.copyCell(cell, table: cell.table,
                startingRow: cell.startingRow + (component == 0 ? 1 : 0),
                rowSpan: cell.rowSpan + (component == 1 ? 1 : 0),
                startingColumn: cell.startingColumn + (component == 2 ? 1 : 0),
                columnSpan: cell.columnSpan + (component == 3 ? 1 : 0))
            Self.replaceCell(in: changed, site: first, with: replacement)
            #expect(Self.renderingDifference(baseline, changed) != nil)
        }

        let sameProperties = document()
        let original = try #require(Self.tableCellSites(sameProperties).first)
        Self.replaceCell(in: sameProperties, site: original,
            with: Self.copyCell(original.cell, table: original.cell.table))
        #expect(Self.renderingDifference(baseline, sameProperties) == nil)
        let wrongCellStyle = document()
        let styled = try #require(Self.tableCellSites(wrongCellStyle).first)
        styled.cell.setWidth(19, type: .absoluteValueType, for: .padding, edge: .maxY)
        #expect(Self.renderingDifference(baseline, wrongCellStyle) != nil)

        let split = document()
        let sharedSites = Self.tableCellSites(split)
        let first = try #require(sharedSites.first)
        let sameTableCell = try #require(sharedSites.dropFirst().first { $0.cell.table === first.cell.table })
        let separateTable = first.cell.table.copy() as! NSTextTable
        Self.replaceCell(in: split, site: sameTableCell,
            with: Self.copyCell(sameTableCell.cell, table: separateTable))
        #expect(Self.renderingDifference(baseline, split) != nil)
        #expect(Self.renderingDifference(split, baseline) != nil)

        let merged = document()
        let independentSites = Self.tableCellSites(merged)
        let firstTable = try #require(independentSites.first?.cell.table)
        let otherTableCell = try #require(independentSites.first { $0.cell.table !== firstTable })
        Self.replaceCell(in: merged, site: otherTableCell,
            with: Self.copyCell(otherTableCell.cell, table: firstTable))
        #expect(Self.renderingDifference(baseline, merged) != nil)
        #expect(Self.renderingDifference(merged, baseline) != nil)
        #expect(Self.renderingDifference(baseline, document()) == nil)
    }

    @Test func transcriptTableComparisonStillRejectsUnknownSubclasses() throws {
        let message = ChatMessageUI(role: .assistant, content: "| A | B |\n| --- | --- |\n| C | D |")
        let baseline = ReadOnlyAttributedTextView.sanitized(ChatTranscriptFormatter.attributedString([message]))
        let unknownBlock = NSMutableAttributedString(attributedString: baseline)
        let first = try #require(Self.tableCellSites(unknownBlock).first)
        let style = first.style.mutableCopy() as! NSMutableParagraphStyle
        style.textBlocks = style.textBlocks.map { $0 === first.cell ? UnsupportedReadingBlock() : $0 }
        unknownBlock.addAttribute(.paragraphStyle, value: style, range: first.range)
        #expect(Self.renderingDifference(unknownBlock, unknownBlock) != nil)
        let unknownTable = NSMutableAttributedString(attributedString: baseline)
        let tableSite = try #require(Self.tableCellSites(unknownTable).first)
        Self.replaceCell(in: unknownTable, site: tableSite,
            with: Self.copyCell(tableSite.cell, table: UnsupportedReadingTable()))
        #expect(Self.renderingDifference(unknownTable, unknownTable) != nil)
    }

    private final class UnsupportedReadingBlock: NSTextBlock {}
    private final class UnsupportedReadingTable: NSTextTable {}
    private typealias TableCellSite = (range: NSRange, style: NSParagraphStyle, cell: NSTextTableBlock)

    private static func tableCellSites(_ document: NSAttributedString) -> [TableCellSite] {
        var sites: [TableCellSite] = []
        document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for case let cell as NSTextTableBlock in style.textBlocks {
                sites.append((range, style, cell))
            }
        }
        return sites
    }

    private static func replaceCell(in document: NSMutableAttributedString, site: TableCellSite, with cell: NSTextTableBlock) {
        let style = site.style.mutableCopy() as! NSMutableParagraphStyle
        style.textBlocks = style.textBlocks.map { $0 === site.cell ? cell : $0 }
        document.addAttribute(.paragraphStyle, value: style, range: site.range)
    }

    // Fixture construction only: preserve inherited values so a placement or
    // table-sharing mutation cannot fail merely because geometry was reset.
    private static func copyCell(_ source: NSTextTableBlock, table: NSTextTable,
        startingRow: Int? = nil, rowSpan: Int? = nil, startingColumn: Int? = nil, columnSpan: Int? = nil
    ) -> NSTextTableBlock {
        let cell = NSTextTableBlock(table: table,
            startingRow: startingRow ?? source.startingRow, rowSpan: rowSpan ?? source.rowSpan,
            startingColumn: startingColumn ?? source.startingColumn, columnSpan: columnSpan ?? source.columnSpan)
        cell.backgroundColor = source.backgroundColor
        cell.verticalAlignment = source.verticalAlignment
        let dimensions: [NSTextBlock.Dimension] = [.width, .minimumWidth, .maximumWidth, .height, .minimumHeight, .maximumHeight]
        for dimension in dimensions {
            cell.setValue(source.value(for: dimension), type: source.valueType(for: dimension), for: dimension)
        }
        let edges: [NSRectEdge] = [.minX, .maxX, .minY, .maxY]
        for edge in edges {
            cell.setBorderColor(source.borderColor(for: edge), for: edge)
            let layers: [NSTextBlock.Layer] = [.padding, .border, .margin]
            for layer in layers {
                cell.setWidth(source.width(for: layer, edge: edge),
                    type: source.widthValueType(for: layer, edge: edge), for: layer, edge: edge)
            }
        }
        return cell
    }

    @Test func fullRebuildKeepsSanitizedMessageOffsetsAndTailSafety() {
        let secret = "owned-cache-construction-secret"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let history = ChatMessageUI(role: .user, content: "原文\u{FFFC}\(secret)")
        let reply = ChatMessageUI(role: .assistant, content: "可见回复", isStreaming: true)
        let session = UUID()
        let cache = ChatTranscriptDocumentCache()
        let initial = cache.render(sessionID: session, messages: [history, reply], baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 2)
        #expect(!initial.attributedString.string.contains(secret))
        #expect(!initial.attributedString.string.contains("\u{FFFC}"))
        #expect(initial.attributedString.string.contains("[附件内容已隐藏]"))
        let roleRange = (initial.attributedString.string as NSString).range(of: "助手\n")
        #expect(roleRange.location != NSNotFound)
        #expect(initial.messageStartLocations[1] == roleRange.location)
        let prefixRange = NSRange(location: 0, length: initial.messageStartLocations[1])
        let prefix = initial.attributedString.attributedSubstring(from: prefixRange)
        let generation = cache.update.generation
        let extended = ChatMessageUI(id: reply.id, role: .assistant, content: "可见回复继续", isStreaming: true)
        let patched = cache.render(sessionID: session, messages: [history, extended], baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 1)
        #expect(cache.update.generation == generation)
        #expect(cache.update.replacementStart == roleRange.location)
        #expect(patched.attributedString.attributedSubstring(from: prefixRange).isEqual(to: prefix))
        #expect(!patched.attributedString.string.contains(secret))
        #expect(!patched.attributedString.string.contains("\u{FFFC}"))
        let full = ReadOnlyAttributedTextView.sanitized(
            ChatTranscriptFormatter.attributedString([history, extended], redactor: redactor))
        #expect(Self.renderingDifference(patched.attributedString, full) == nil)
    }

    @Test func mixedMarkdownTailPatchMatchesFullRenderAtBothTextKitStages() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: Self.longMixedContent)
        let replyID = UUID()
        let first = ChatMessageUI(id: replyID, role: .assistant, content: "", isStreaming: true)
        let streamed = ChatMessageUI(id: replyID, role: .assistant, content: Self.longMixedContent, isStreaming: true)
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let initial = cache.render(sessionID: session, messages: [history, first], baseSize: 13, redactor: redactor)
        let native = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let coordinator = native.makeCoordinator()
        let scroll = native.makeNSView(coordinator: coordinator)
        defer { ReadOnlyAttributedTextView.dismantleNSView(scroll, coordinator: coordinator) }
        let nativeText = try #require(scroll.documentView as? NSTextView)
        let storage = try #require(nativeText.textStorage)
        storage.ensureAttributesAreFixed(in: NSRange(location: 0, length: storage.length))
        let initialFull = ChatTranscriptFormatter.formattedDocument(
            [history, first], redactor: redactor).attributedString
        #expect(Self.renderingDifference(initial.attributedString, initialFull) == nil)
        let initialControl = try Self.fullTranscriptConsumer([history, first], redactor: redactor, matching: nativeText)
        defer { ReadOnlyAttributedTextView.dismantleNSView(initialControl.scroll, coordinator: initialControl.coordinator) }
        let initialFullStorage = initialControl.storage
        #expect(Self.renderingDifference(storage, initialFullStorage) == nil)
        for width: CGFloat in [600, 760] {
            #expect(Self.layoutDifference(storage, initialFullStorage, width: width) == nil)
        }
        let tailAt = initial.messageStartLocations[1]
        let prefixRange = NSRange(location: 0, length: tailAt)
        let cachePrefix = initial.attributedString.attributedSubstring(from: prefixRange)
        let storagePrefix = storage.attributedSubstring(from: prefixRange)
        let generation = cache.update.generation
        let patched = cache.render(sessionID: session, messages: [history, streamed], baseSize: 13, redactor: redactor)
        #expect(cache.update.replacementStart == tailAt)
        #expect(cache.update.generation == generation)
        #expect(patched.attributedString.attributedSubstring(from: prefixRange).isEqual(to: cachePrefix))
        ReadOnlyAttributedTextView(transcriptDocument: patched, update: cache.update)
            .updateNSView(scroll, coordinator: coordinator)
        #expect(storage.attributedSubstring(from: prefixRange).isEqual(to: storagePrefix))
        let full = ChatTranscriptFormatter.formattedDocument(
            [history, streamed], redactor: redactor).attributedString
        #expect(Self.renderingDifference(patched.attributedString, full) == nil)
        let fullControl = try Self.fullTranscriptConsumer([history, streamed], redactor: redactor, matching: nativeText)
        defer { ReadOnlyAttributedTextView.dismantleNSView(fullControl.scroll, coordinator: fullControl.coordinator) }
        let repeatedControl = try Self.fullTranscriptConsumer([history, streamed], redactor: redactor, matching: nativeText)
        defer { ReadOnlyAttributedTextView.dismantleNSView(repeatedControl.scroll, coordinator: repeatedControl.coordinator) }
        let fullStorage = fullControl.storage
        #expect(Self.renderingDifference(fullStorage, repeatedControl.storage) == nil)
        #expect(Self.renderingDifference(storage, fullStorage) == nil)
        for width: CGFloat in [600, 760] {
            #expect(Self.layoutDifference(storage, fullStorage, width: width) == nil)
        }
    }

    @Test func transcriptSanitizerSegmentationAndNativeStorageSetterMatchFullRender() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: Self.longMixedContent)
        let first = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let raw = ChatTranscriptFormatter.formattedDocument([history, first], redactor: redactor)
        let whole = ReadOnlyAttributedTextView.sanitized(raw.attributedString)
        let segmented = NSMutableAttributedString(string: "")
        let tailAt = raw.messageStartLocations[1]
        for range in [NSRange(location: 0, length: tailAt - 2),
                      NSRange(location: tailAt - 2, length: 2),
                      NSRange(location: tailAt, length: raw.attributedString.length - tailAt)] {
            segmented.append(ReadOnlyAttributedTextView.sanitized(raw.attributedString.attributedSubstring(from: range)))
        }
        #expect(segmented.isEqual(to: whole))
        #expect(Self.renderingDifference(Self.consumerStorage(segmented), Self.consumerStorage(whole)) == nil)
        for width: CGFloat in [600, 760] {
            #expect(Self.layoutDifference(segmented, whole, width: width) == nil)
        }

        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let initial = cache.render(sessionID: session, messages: [history, first], baseSize: 13, redactor: redactor)
        // The generic sanitizer checks above remain separate and closed.
        // Trusted transcript mounting keeps private icons via the real consumer.
        let native = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let coordinator = native.makeCoordinator()
        let scroll = native.makeNSView(coordinator: coordinator)
        defer { ReadOnlyAttributedTextView.dismantleNSView(scroll, coordinator: coordinator) }
        let nativeText = try #require(scroll.documentView as? NSTextView)
        let patchedStorage = try #require(nativeText.textStorage)
        let initialControl = try Self.fullTranscriptConsumer([history, first], redactor: redactor, matching: nativeText)
        defer { ReadOnlyAttributedTextView.dismantleNSView(initialControl.scroll, coordinator: initialControl.coordinator) }
        let initialFullStorage = initialControl.storage
        #expect(Self.renderingDifference(patchedStorage, initialFullStorage) == nil)
        for width: CGFloat in [600, 760] {
            #expect(Self.layoutDifference(patchedStorage, initialFullStorage, width: width) == nil)
        }
        let prefixRange = NSRange(location: 0, length: tailAt)
        let prefix = patchedStorage.attributedSubstring(from: prefixRange)
        let streamed = ChatMessageUI(id: first.id, role: .assistant, content: Self.longMixedContent, isStreaming: true)
        let updated = cache.render(sessionID: session, messages: [history, streamed], baseSize: 13, redactor: redactor)
        #expect(cache.update.replacementStart == tailAt)
        ReadOnlyAttributedTextView(transcriptDocument: updated, update: cache.update)
            .updateNSView(scroll, coordinator: coordinator)
        #expect(patchedStorage.attributedSubstring(from: prefixRange).isEqual(to: prefix))
        let fullControl = try Self.fullTranscriptConsumer([history, streamed], redactor: redactor, matching: nativeText)
        defer { ReadOnlyAttributedTextView.dismantleNSView(fullControl.scroll, coordinator: fullControl.coordinator) }
        let fullStorage = fullControl.storage
        #expect(Self.renderingDifference(patchedStorage, fullStorage) == nil)
        for width: CGFloat in [600, 760] {
            #expect(Self.layoutDifference(patchedStorage, fullStorage, width: width) == nil)
        }
    }

    @Test func transcriptCacheInvalidatesOnHistoryPolicyStyleAndSessionChanges() {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let historyID = UUID()
        let secret = "sk-policy-private-abc123"
        let original = ChatMessageUI(id: historyID, role: .user, content: "原文 \(secret)")
        let reply = ChatMessageUI(role: .assistant, content: "回复")
        let noSecrets = ChatTranscriptRedactor(secretValues: [])
        let protected = ChatTranscriptRedactor(secretValues: [secret])

        _ = cache.render(sessionID: session, messages: [original, reply], baseSize: 13, redactor: noSecrets)
        let stableRevision = cache.update.revision
        _ = cache.render(sessionID: session, messages: [original, reply], baseSize: 13, redactor: noSecrets)
        #expect(cache.update.revision == stableRevision)

        _ = cache.render(sessionID: session, messages: [original, reply], baseSize: 13, redactor: protected)
        #expect(cache.update.replacementStart == nil)
        #expect(!cache.document.attributedString.string.contains(secret))
        #expect(!cache.accessibilityText.contains(secret))

        let edited = ChatMessageUI(id: historyID, role: .user, content: "改写历史")
        _ = cache.render(sessionID: session, messages: [edited, reply], baseSize: 13, redactor: protected)
        #expect(cache.update.replacementStart == nil)
        #expect(cache.document.attributedString.string.contains("改写历史"))

        _ = cache.render(sessionID: session, messages: [edited, reply], baseSize: 17, redactor: protected)
        #expect(cache.update.replacementStart == nil)
        _ = cache.render(sessionID: UUID(), messages: [reply], baseSize: 17, redactor: protected)
        #expect(cache.update.replacementStart == nil)
        #expect(!cache.document.attributedString.string.contains("改写历史"))
    }

    @Test func rolePaletteChangeInvalidatesDocumentWhileSteadyTailStaysIncremental() {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "历史正文")
        let replyID = UUID()
        let first = ChatMessageUI(id: replyID, role: .assistant, content: "第一段", isStreaming: true)
        let light = Aj38Palette.light
        let dark = Aj38Palette.dark

        _ = cache.render(
            sessionID: session, messages: [history, first], baseSize: 13,
            redactor: redactor, palette: light
        )
        let stableRevision = cache.update.revision
        let stableGeneration = cache.update.generation
        _ = cache.render(
            sessionID: session, messages: [history, first], baseSize: 13,
            redactor: redactor, palette: light
        )
        #expect(cache.update.revision == stableRevision)

        let next = ChatMessageUI(id: replyID, role: .assistant, content: "第一段第二段", isStreaming: true)
        let tail = cache.render(
            sessionID: session, messages: [history, next], baseSize: 13,
            redactor: redactor, palette: light
        )
        #expect(cache.update.replacementStart == tail.messageStartLocations[1])
        #expect(cache.update.generation == stableGeneration)
        let prefix = (tail.attributedString.string as NSString).substring(
            to: tail.messageStartLocations[1]
        )
        let lightStyle = tail.attributedString.attribute(
            .paragraphStyle, at: tail.messageStartLocations[0], effectiveRange: nil
        ) as? NSParagraphStyle
        let lightBackground = lightStyle?.textBlocks.first?.backgroundColor

        let recolored = cache.render(
            sessionID: session, messages: [history, next], baseSize: 13,
            redactor: redactor, palette: dark
        )
        #expect(cache.update.replacementStart == nil)
        #expect(cache.update.generation == stableGeneration + 1)
        #expect((recolored.attributedString.string as NSString).substring(
            to: recolored.messageStartLocations[1]
        ) == prefix)
        let userAt = recolored.messageStartLocations[0]
        let style = recolored.attributedString.attribute(
            .paragraphStyle, at: userAt, effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style?.textBlocks.first?.backgroundColor != nil)
        #expect(style?.textBlocks.first?.backgroundColor != lightBackground)

        let accented = dark.withAccent((r: 0.2, g: 0.4, b: 0.6))
        _ = cache.render(
            sessionID: session, messages: [history, next], baseSize: 13,
            redactor: redactor, palette: accented
        )
        #expect(cache.update.replacementStart == nil)
        #expect(cache.messageOffsets(contentWidth: 600).count == 2)
        #expect(cache.messageOffsets(contentWidth: 800).count == 2)
    }

    @Test func emptyStreamingAssistantKeepsRoleTitleAndRenderOnlyPlaceholder() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let streaming = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let document = ChatTranscriptFormatter.formattedDocument([streaming], palette: .light)
        #expect(document.attributedString.string == "助手\n\u{FFFC} 生成中…")
        #expect(document.attributedString.attribute(.attachment, at: 3, effectiveRange: nil) is NSTextAttachment)
        #expect(ChatTranscriptFormatter.plainText([streaming]) == "【助手】")
        #expect(ChatTranscriptFormatter.accessibilityText([streaming]) == "助手：生成中…")
        #expect(document.messageStartLocations == [0])
    }

    @Test func longTranscriptTailPatchKeepsPrefixAndAnchorAtFiftyAndHundredThousand() {
        let redactor = ChatTranscriptRedactor(secretValues: [])
        for size in [50_000, 100_000] {
            let cache = ChatTranscriptDocumentCache()
            let session = UUID()
            let history = ChatMessageUI(role: .user, content: String(repeating: "史", count: size))
            let replyID = UUID()
            let first = ChatMessageUI(id: replyID, role: .assistant, content: "开始", isStreaming: true)
            let initial = cache.render(
                sessionID: session, messages: [history, first], baseSize: 13,
                redactor: redactor, palette: .light
            )
            let historicalAnchor = initial.messageStartLocations[1]
            let historicalPrefix = (initial.attributedString.string as NSString).substring(
                to: historicalAnchor
            )
            let generation = cache.update.generation
            let streamed = ChatMessageUI(
                id: replyID, role: .assistant, content: "开始，继续生成", isStreaming: true
            )
            let updated = cache.render(
                sessionID: session, messages: [history, streamed], baseSize: 13,
                redactor: redactor, palette: .light
            )
            #expect(cache.update.replacementStart == historicalAnchor)
            #expect(cache.update.generation == generation)
            #expect(updated.messageStartLocations == initial.messageStartLocations)
            #expect((updated.attributedString.string as NSString).substring(
                to: historicalAnchor
            ) == historicalPrefix)
        }
    }

    @Test func markdownBlockKindsUseExplicitReadingRhythm() {
        #expect(ChatReadingLayout.maxContentWidth == 760)
        #expect(ChatReadingLayout.horizontalInset == 28)
        #expect(ChatReadingLayout.blockSpacing == 12)
        #expect(ChatReadingLayout.headingTopSpacing(level: 1) == 8)
        #expect(ChatReadingLayout.headingTopSpacing(level: 3) == 6)
        #expect(ChatReadingLayout.headingBottomSpacing == 2)
        #expect(ChatReadingLayout.listItemSpacing == 5)
        #expect(ChatReadingLayout.listMarkerSpacing == 8)
        #expect(ChatReadingLayout.blockquoteVerticalPadding == 8)
        #expect(ChatReadingLayout.codeVerticalPadding == 10)
        #expect(ChatReadingLayout.tableColumnSpacing == 16)
        #expect(ChatReadingLayout.tableRowSpacing == 8)
        #expect(ChatReadingLayout.tablePadding == 10)
    }

    /// Independent formatter calls allocate new role blocks. Ignore only their
    /// addresses: retain every attribute, all public block layout properties,
    /// and bijections of shared blocks and tables across paragraphs/messages.
    /// Accept only plain role blocks and O15's concrete table cells/tables;
    /// unknown subclasses still fail closed.
    static func renderingDifference(
        _ left: NSAttributedString, _ right: NSAttributedString
    ) -> String? {
        (left as? NSTextStorage)?.ensureAttributesAreFixed(in: NSRange(location: 0, length: left.length))
        (right as? NSTextStorage)?.ensureAttributesAreFixed(in: NSRange(location: 0, length: right.length))
        guard left.string == right.string else { return "text differs" }
        var leftBlocks: [ObjectIdentifier: ObjectIdentifier] = [:]
        var rightBlocks: [ObjectIdentifier: ObjectIdentifier] = [:]
        var leftTables: [ObjectIdentifier: ObjectIdentifier] = [:]
        var rightTables: [ObjectIdentifier: ObjectIdentifier] = [:]
        var offset = 0
        while offset < left.length {
            var leftRange = NSRange()
            var rightRange = NSRange()
            var leftAttributes = left.attributes(at: offset, effectiveRange: &leftRange)
            var rightAttributes = right.attributes(at: offset, effectiveRange: &rightRange)
            let leftParagraph = leftAttributes.removeValue(forKey: .paragraphStyle)
            let rightParagraph = rightAttributes.removeValue(forKey: .paragraphStyle)
            if let a = leftParagraph as? NSParagraphStyle, let b = rightParagraph as? NSParagraphStyle {
                guard a.textBlocks.count == b.textBlocks.count else { return "block count differs at \(offset)" }
                for (aBlock, bBlock) in zip(a.textBlocks, b.textBlocks) {
                    if let aCell = aBlock as? NSTextTableBlock, let bCell = bBlock as? NSTextTableBlock {
                        guard type(of: aCell) == NSTextTableBlock.self,
                              type(of: bCell) == NSTextTableBlock.self,
                              type(of: aCell.table) == NSTextTable.self,
                              type(of: bCell.table) == NSTextTable.self else { return "unsupported table block at \(offset)" }
                        guard aCell.startingRow == bCell.startingRow,
                              aCell.rowSpan == bCell.rowSpan,
                              aCell.startingColumn == bCell.startingColumn,
                              aCell.columnSpan == bCell.columnSpan else { return "cell placement differs at \(offset)" }
                        let aTable = aCell.table
                        let bTable = bCell.table
                        guard aTable.numberOfColumns == bTable.numberOfColumns,
                              aTable.layoutAlgorithm == bTable.layoutAlgorithm,
                              aTable.collapsesBorders == bTable.collapsesBorders,
                              aTable.hidesEmptyCells == bTable.hidesEmptyCells,
                              blocksMatch(aTable, bTable) else { return "table style differs at \(offset)" }
                        let aTableID = ObjectIdentifier(aTable)
                        let bTableID = ObjectIdentifier(bTable)
                        if let paired = leftTables[aTableID], paired != bTableID { return "table sharing differs at \(offset)" }
                        if let paired = rightTables[bTableID], paired != aTableID { return "table sharing differs at \(offset)" }
                        leftTables[aTableID] = bTableID
                        rightTables[bTableID] = aTableID
                    } else {
                        guard type(of: aBlock) == NSTextBlock.self,
                              type(of: bBlock) == NSTextBlock.self else { return "unsupported block at \(offset)" }
                    }
                    let aID = ObjectIdentifier(aBlock)
                    let bID = ObjectIdentifier(bBlock)
                    if let paired = leftBlocks[aID], paired != bID { return "block sharing differs at \(offset)" }
                    if let paired = rightBlocks[bID], paired != aID { return "block sharing differs at \(offset)" }
                    guard blocksMatch(aBlock, bBlock) else { return "block style differs at \(offset)" }
                    leftBlocks[aID] = bID
                    rightBlocks[bID] = aID
                }
                let aStyle = a.mutableCopy() as! NSMutableParagraphStyle
                let bStyle = b.mutableCopy() as! NSMutableParagraphStyle
                aStyle.textBlocks = []
                bStyle.textBlocks = []
                guard aStyle.isEqual(bStyle) else { return "paragraph style differs at \(offset)" }
            } else if leftParagraph != nil || rightParagraph != nil {
                return "paragraph attribute differs at \(offset)"
            }
            // Display attachments are independently built objects. Compare
            // their closed producer identity, original/AX semantics, bounds and
            // actual image bytes before the unchanged remaining-attribute gate.
            let character = NSRange(location: offset, length: 1)
            let aRun = left.attributedSubstring(from: character)
            let bRun = right.attributedSubstring(from: character)
            let aIcon = ChatTranscriptStatusIconProjection.containsIcons(aRun)
            let bIcon = ChatTranscriptStatusIconProjection.containsIcons(bRun)
            if aIcon || bIcon {
                guard aIcon && bIcon,
                      let a = leftAttributes[.attachment] as? NSTextAttachment,
                      let b = rightAttributes[.attachment] as? NSTextAttachment,
                      type(of: a) == type(of: b), a.bounds == b.bounds,
                      let aImage = a.image, let bImage = b.image,
                      aImage.size == bImage.size,
                      let aBytes = aImage.tiffRepresentation, let bBytes = bImage.tiffRepresentation,
                      aBytes == bBytes,
                      ChatTranscriptStatusIconProjection.copyText(aRun)
                        == ChatTranscriptStatusIconProjection.copyText(bRun),
                      ChatTranscriptStatusIconProjection.accessibilityText(aRun)
                        == ChatTranscriptStatusIconProjection.accessibilityText(bRun) else {
                    return "status attachment semantics or pixels differ at \(offset)"
                }
                leftAttributes.removeValue(forKey: .attachment)
                rightAttributes.removeValue(forKey: .attachment)
            }
            guard NSDictionary(dictionary: leftAttributes).isEqual(NSDictionary(dictionary: rightAttributes)) else {
                let keys = Set(leftAttributes.keys).union(rightAttributes.keys).sorted { $0.rawValue < $1.rawValue }
                let differences = keys.compactMap { key -> String? in
                    let a = leftAttributes[key]
                    let b = rightAttributes[key]
                    if let a = a as? NSObject, let b = b as? NSObject, a.isEqual(b) { return nil }
                    if a == nil && b == nil { return nil }
                    let fontEvidence: String
                    if let a = a as? NSFont, let b = b as? NSFont {
                        fontEvidence = "; " + fontPairEvidence(a, b, text: (left.string as NSString).substring(with: NSIntersectionRange(leftRange, rightRange)))
                    } else {
                        fontEvidence = ""
                    }
                    return "\(key.rawValue): \(attributeSummary(a)) vs \(attributeSummary(b))\(fontEvidence)"
                }
                return "attributes differ at \(offset): " + differences.joined(separator: "; ")
            }
            offset = min(NSMaxRange(leftRange), NSMaxRange(rightRange))
        }
        return nil
    }

    /// Test-only compact attribute diagnostics. Never include document text.
    private static func attributeSummary(_ value: Any?) -> String {
        guard let value else { return "absent" }
        if let font = value as? NSFont {
            return "font(name=\(font.fontName), size=\(font.pointSize), descriptor=\(font.fontDescriptor))"
        }
        return String(String(describing: value).prefix(300))
    }

    /// Diagnostics only: the original NSFont equality failure still fails.
    /// Use the existing toll-free CTFont objects, not newly recreated fonts.
    private static func fontPairEvidence(_ left: NSFont, _ right: NSFont, text: String) -> String {
        let a = left as CTFont
        let b = right as CTFont
        let aDescriptor = CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(a))
        let bDescriptor = CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(b))
        func cfEqual(_ a: CFTypeRef?, _ b: CFTypeRef?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return CFEqual(a, b)
            default: return false
            }
        }
        let aMetrics = [CTFontGetSize(a), CTFontGetAscent(a), CTFontGetDescent(a), CTFontGetLeading(a),
                        CTFontGetCapHeight(a), CTFontGetXHeight(a), CTFontGetUnderlinePosition(a), CTFontGetUnderlineThickness(a)]
        let bMetrics = [CTFontGetSize(b), CTFontGetAscent(b), CTFontGetDescent(b), CTFontGetLeading(b),
                        CTFontGetCapHeight(b), CTFontGetXHeight(b), CTFontGetUnderlinePosition(b), CTFontGetUnderlineThickness(b)]
        let characters = Array(text.utf16)
        var aGlyphs = [CGGlyph](repeating: 0, count: characters.count)
        var bGlyphs = aGlyphs
        let aCovers = CTFontGetGlyphsForCharacters(a, characters, &aGlyphs, characters.count)
        let bCovers = CTFontGetGlyphsForCharacters(b, characters, &bGlyphs, characters.count)
        var aAdvances = [CGSize](repeating: .zero, count: characters.count)
        var bAdvances = aAdvances
        var aBounds = [CGRect](repeating: .zero, count: characters.count)
        var bBounds = aBounds
        let aAdvance = CTFontGetAdvancesForGlyphs(a, .horizontal, aGlyphs, &aAdvances, aGlyphs.count)
        let bAdvance = CTFontGetAdvancesForGlyphs(b, .horizontal, bGlyphs, &bAdvances, bGlyphs.count)
        let aBound = CTFontGetBoundingRectsForGlyphs(a, .horizontal, aGlyphs, &aBounds, aGlyphs.count)
        let bBound = CTFontGetBoundingRectsForGlyphs(b, .horizontal, bGlyphs, &bBounds, bGlyphs.count)
        let aNSAdvances = aGlyphs.map { left.advancement(forCGGlyph: $0) }
        let bNSAdvances = bGlyphs.map { right.advancement(forCGGlyph: $0) }
        let aLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: left]))
        let bLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: right]))
        let aLineWidth = CTLineGetTypographicBounds(aLine, nil, nil, nil)
        let bLineWidth = CTLineGetTypographicBounds(bLine, nil, nil, nil)
        let aOpticalSize = CTFontCopyAttribute(a, kCTFontOpticalSizeAttribute)
        let bOpticalSize = CTFontCopyAttribute(b, kCTFontOpticalSizeAttribute)
        let checks: [(String, Bool)] = [
            ("CF font", CFEqual(a, b)),
            ("NS descriptor all attributes", NSDictionary(dictionary: left.fontDescriptor.fontAttributes).isEqual(NSDictionary(dictionary: right.fontDescriptor.fontAttributes))),
            ("CT descriptor all attributes", CFEqual(aDescriptor, bDescriptor)),
            ("symbolic traits", CTFontGetSymbolicTraits(a) == CTFontGetSymbolicTraits(b)),
            ("traits dictionary", CFEqual(CTFontCopyTraits(a), CTFontCopyTraits(b))),
            ("matrix", CTFontGetMatrix(a) == CTFontGetMatrix(b)),
            ("optical size", cfEqual(aOpticalSize, bOpticalSize)),
            ("NS render mode", left.renderingMode == right.renderingMode),
            ("NS vertical/fixedPitch", left.isVertical == right.isVertical && left.isFixedPitch == right.isFixedPitch),
            ("NS glyph advances", aNSAdvances == bNSAdvances),
            ("CT shaped line", aLineWidth == bLineWidth),
            ("variation", cfEqual(CTFontCopyVariation(a), CTFontCopyVariation(b))),
            ("features", cfEqual(CTFontCopyFeatures(a), CTFontCopyFeatures(b))),
            ("feature settings", cfEqual(CTFontCopyFeatureSettings(a), CTFontCopyFeatureSettings(b))),
            ("character set", CFEqual(CTFontCopyCharacterSet(a), CTFontCopyCharacterSet(b))),
            ("metrics", aMetrics == bMetrics && CTFontGetBoundingBox(a) == CTFontGetBoundingBox(b)),
            ("glyph IDs", aCovers == bCovers && aGlyphs == bGlyphs && CTFontGetGlyphCount(a) == CTFontGetGlyphCount(b) && CTFontGetUnitsPerEm(a) == CTFontGetUnitsPerEm(b)),
            ("glyph advances", aAdvance == bAdvance && aAdvances == bAdvances),
            ("glyph bounds", aBound == bBound && aBounds == bBounds)
        ]
        return checks.map { "\($0.0) equal=\($0.1)" }.joined(separator: ", ")
            + "; CT shaped widths=\(aLineWidth)/\(bLineWidth), optical size=\(String(describing: aOpticalSize))/\(String(describing: bOpticalSize)), NS modes=\(left.renderingMode.rawValue)/\(right.renderingMode.rawValue)"
            + "; CT descriptor left=\(aDescriptor), right=\(bDescriptor)"
    }

    /// Rebuild the independent full oracle from original messages and mount
    /// it through the same real transcript consumer as the incremental side.
    private static func fullTranscriptConsumer(_ messages: [ChatMessageUI], redactor: ChatTranscriptRedactor,
        matching reference: NSTextView) throws
        -> (storage: NSTextStorage, scroll: NSScrollView, coordinator: ReadOnlyAttributedTextView.Coordinator) {
        let document = ChatTranscriptFormatter.formattedDocument(messages, redactor: redactor)
        let component = ReadOnlyAttributedTextView(transcriptDocument: document,
            update: ChatTranscriptStorageUpdate(revision: 1, generation: 1, replacementStart: nil, replacement: nil))
        let coordinator = component.makeCoordinator()
        let scroll = component.makeNSView(coordinator: coordinator)
        let text = try #require(scroll.documentView as? NSTextView)
        let appearance = reference.effectiveAppearance
        reference.appearance = appearance
        scroll.appearance = appearance
        text.appearance = appearance
        text.textContainerInset = reference.textContainerInset
        let source = try #require(reference.textContainer)
        let target = try #require(text.textContainer)
        target.containerSize = source.containerSize
        target.widthTracksTextView = source.widthTracksTextView
        target.heightTracksTextView = source.heightTracksTextView
        target.lineFragmentPadding = source.lineFragmentPadding
        target.lineBreakMode = source.lineBreakMode
        #expect(text.window?.backingScaleFactor == reference.window?.backingScaleFactor)
        #expect(text.layer?.contentsScale == reference.layer?.contentsScale)
        let storage = try #require(text.textStorage)
        return (storage, scroll, coordinator)
    }

    /// Match makeNSView/updateNSView's real NSTextStorage consumer write.
    /// The convenience attributed-string initializer produces different fallback
    /// shaping for mutable vs immutable inputs on this macOS SDK/runtime, even
    /// for attributed strings that are equal before fixing. Keep strict font and
    /// layout checks on the same actual consumer operation instead.
    private static func consumerStorage(_ document: NSAttributedString) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(document)
        return storage
    }

    /// Actual production TextKit glyph/position/line geometry, without opening
    /// a view or an App. No normalization and no tolerance for changed layout.
    private static func layoutDifference(_ left: NSAttributedString, _ right: NSAttributedString, width: CGFloat) -> String? {
        func facts(_ document: NSAttributedString) -> [String] {
            let storage = consumerStorage(document)
            let manager = NSLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = ReadOnlyAttributedTextView.transcriptLineBreakMode
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            var result = ["used=\(manager.usedRect(for: container))", "glyphCount=\(manager.numberOfGlyphs)"]
            for glyph in 0..<manager.numberOfGlyphs {
                result.append("\(manager.glyph(at: glyph))/\(manager.characterIndexForGlyph(at: glyph))/\(manager.location(forGlyphAt: glyph))/\(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))/\(manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil))")
            }
            return result
        }
        let a = facts(left)
        let b = facts(right)
        guard a.count == b.count else { return "layout glyph count differs at width \(width)" }
        for index in a.indices where a[index] != b[index] {
            return "layout differs at width \(width), entry \(index): \(a[index]) vs \(b[index])"
        }
        return nil
    }

    private static func blocksMatch(_ left: NSTextBlock, _ right: NSTextBlock) -> Bool {
        guard left.backgroundColor == right.backgroundColor,
              left.verticalAlignment == right.verticalAlignment else { return false }
        let dimensions: [NSTextBlock.Dimension] = [.width, .minimumWidth, .maximumWidth, .height, .minimumHeight, .maximumHeight]
        for dimension in dimensions {
            guard left.value(for: dimension) == right.value(for: dimension),
                  left.valueType(for: dimension) == right.valueType(for: dimension) else { return false }
        }
        let edges: [NSRectEdge] = [.minX, .maxX, .minY, .maxY]
        for edge in edges {
            guard left.borderColor(for: edge) == right.borderColor(for: edge) else { return false }
            for layer in [NSTextBlock.Layer.padding, .border, .margin] {
                guard left.width(for: layer, edge: edge) == right.width(for: layer, edge: edge),
                      left.widthValueType(for: layer, edge: edge) == right.widthValueType(for: layer, edge: edge) else { return false }
            }
        }
        return true
    }

    private static let longMixedContent = """
    # 标题：阅读上下文

    用户请求：请把这段中文长段落和 readable content 放在同一个阅读列里。这里有连续的说明文字，用于模拟真实对话中的长篇回答、工具结果和逐步解释，阅读时不能因为角色切换而左右跳动。

    ## 处理步骤

    1. 保留原始语义与选择能力。
    2. Keep English words readable without changing the source text.
    3. 让标题、列表、引用、代码和表格之间有稳定的节奏。

    > 引用：这是来自工具的上下文提示，应该保持清楚的左侧层级和可复制文本。

    ```swift
    let result = items.map { $0.value }
    print("tool output: \\(result)")
    ```

    | 列名 | 状态 | 备注 |
    | --- | --- | --- |
    | 第一行结果 | ready | readable content |
    | 第二行结果 | done | 中文说明 |

    工具输出：
    - command: `swift test --filter UX02ChatReadingTests`
    - exit: 0
    - result: passed
    """
}
