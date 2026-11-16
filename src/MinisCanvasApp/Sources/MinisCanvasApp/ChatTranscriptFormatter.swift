import Foundation
import AppKit
import MinisCore

/// 正文与流式 Markdown 共用的阅读布局事实源。
///
/// 这里仅描述排版，不持有消息内容或解析结果；复制、选择、脱敏和流式状态
/// 仍由各自既有边界负责。
enum ChatReadingLayout {
    static let horizontalInset: CGFloat = 28
    static let maxContentWidth: CGFloat = 760
    static let paragraphSpacingBefore: CGFloat = 8
    static let paragraphSpacing: CGFloat = 10
    static let lineSpacing: CGFloat = 2
    static let blockSpacing: CGFloat = 12
    static let headingBottomSpacing: CGFloat = 2
    static let listItemSpacing: CGFloat = 5
    static let listMarkerSpacing: CGFloat = 8
    static let blockquoteVerticalPadding: CGFloat = 8
    static let codeVerticalPadding: CGFloat = 10
    static let tableColumnSpacing: CGFloat = 16
    static let tableRowSpacing: CGFloat = 8
    static let tablePadding: CGFloat = 10

    static func headingTopSpacing(level: Int) -> CGFloat {
        level <= 2 ? 8 : 6
    }

    /// 正文列宽：可用宽度扣除两侧 gutter，上限 `maxContentWidth`。
    static func columnWidth(availableWidth: CGFloat, gutter: CGFloat) -> CGFloat {
        max(1, min(maxContentWidth, availableWidth - gutter * 2))
    }

    /// 正文列左侧偏移：列在可用宽度内水平居中（窄窗口时等于 gutter）。
    static func columnLeadingInset(availableWidth: CGFloat, gutter: CGFloat) -> CGFloat {
        (availableWidth - columnWidth(availableWidth: availableWidth, gutter: gutter)) / 2
    }

    /// 输入区与正文列共用同一列宽。
    static func composerColumnWidth(availableWidth: CGFloat, gutter: CGFloat) -> CGFloat {
        columnWidth(availableWidth: availableWidth, gutter: gutter)
    }
}

/// 输入卡片外观：常态 1pt borderSubtle 描边、填充与外层分区底色（backgroundSecondary）可区分。
struct ComposerSurfaceStyle: Equatable {
    var fill: ThemeColor
    var stroke: ThemeColor
    var strokeWidth: CGFloat

    static func resolve(palette: Aj38Palette, isFocused: Bool, isDropTargeted: Bool) -> ComposerSurfaceStyle {
        if isDropTargeted {
            return ComposerSurfaceStyle(fill: palette.backgroundPrimary, stroke: palette.accent, strokeWidth: 1.5)
        }
        if isFocused {
            return ComposerSurfaceStyle(fill: palette.backgroundPrimary, stroke: palette.accent, strokeWidth: 1)
        }
        return ComposerSurfaceStyle(fill: palette.backgroundPrimary, stroke: palette.borderSubtle, strokeWidth: 1)
    }
}

/// 会话行外观：未选中无底色，悬停淡底，选中 accent 高亮与描边（悬停不叠加）。
struct SessionRowSurfaceStyle: Equatable {
    var fillColor: ThemeColor
    var fillOpacity: Double
    var edgeOpacity: Double

    static func resolve(isActive: Bool, isHovered: Bool, palette: Aj38Palette) -> SessionRowSurfaceStyle {
        if isActive {
            return SessionRowSurfaceStyle(fillColor: palette.accent, fillOpacity: 0.14, edgeOpacity: 0.4)
        }
        return SessionRowSurfaceStyle(
            fillColor: palette.borderSubtle, fillOpacity: isHovered ? 0.06 : 0, edgeOpacity: 0)
    }
}

/// 会话级文本边界：复制全部和全文选择模式必须使用同一份顺序、角色和分隔规则。
struct ChatTranscriptFormattedDocument {
    let attributedString: NSAttributedString
    /// Each entry is the character location used to anchor that message in the
    /// single NSTextView transcript. The locations are produced while the
    /// document is built, so callers do not need to re-render every prefix.
    let messageStartLocations: [Int]
}

/// A change to the single transcript host. The replacement is already
/// redacted and sanitized; only the changing suffix enters NSTextStorage.
struct ChatTranscriptStorageUpdate {
    let revision: UInt64
    let generation: UInt64
    let diagnosticScope: TranscriptOperationDiagnostics.Scope?
    let replacementStart: Int?
    let replacement: NSAttributedString?
    /// The smaller suffix is valid only against `baseRevision`. The anchored
    /// replacement above remains replayable when SwiftUI skips tail revisions.
    let exactBaseReplacementStart: Int?
    let exactBaseReplacement: NSAttributedString?
    /// A suffix is relative to one exact prior document, not merely its
    /// structural generation. Coalesced updates must use the current document.
    let baseRevision: UInt64?

    init(revision: UInt64, generation: UInt64, replacementStart: Int?,
         replacement: NSAttributedString?, baseRevision: UInt64? = nil,
         exactBaseReplacementStart: Int? = nil,
         exactBaseReplacement: NSAttributedString? = nil,
         diagnosticScope: TranscriptOperationDiagnostics.Scope? = nil) {
        self.revision = revision
        self.generation = generation
        self.diagnosticScope = diagnosticScope
        self.replacementStart = replacementStart
        self.replacement = replacement
        self.baseRevision = baseRevision
        self.exactBaseReplacementStart = exactBaseReplacementStart
        self.exactBaseReplacement = exactBaseReplacement
    }

    func patch(forAppliedRevision appliedRevision: UInt64?)
        -> (start: Int, value: NSAttributedString)? {
        if let baseRevision, appliedRevision == baseRevision,
           let exactBaseReplacementStart, let exactBaseReplacement {
            return (exactBaseReplacementStart, exactBaseReplacement)
        }
        guard let replacementStart, let replacement else { return nil }
        return (replacementStart, replacement)
    }
}

/// View-local cache. Historical messages are rendered once and retained while
/// only the live tail changes. Every unsafe transition takes the full path:
/// session, redaction policy, typography, historical edit, delete or reorder.
final class ChatTranscriptDocumentCache {
    private var renderedText = NSMutableAttributedString(string: "")
    private var accessibleText = NSMutableString(string: "")
    private var accessibilityTailLength = 0
    private(set) var document = ChatTranscriptFormattedDocument(
        attributedString: NSAttributedString(string: ""), messageStartLocations: []
    )
    private(set) var accessibilityText = ""
    private var cachedAccessibilityValue: (revision: UInt64, status: String, value: String)?
    private(set) var accessibilityValueBuildCount = 0
    private var cachedFallbackRouteStatus: (revision: UInt64, value: String?)?
    private(set) var fallbackRouteCheckCount = 0
    private(set) var update = ChatTranscriptStorageUpdate(
        revision: 0, generation: 0, replacementStart: nil, replacement: nil
    )
    private var sessionID: UUID?
    private var messages: [ChatMessageUI] = []
    private var inlineToolGaps: [UUID: [ChatInlineToolGap]] = [:]
    private var expandedToolOutputIDs: Set<UUID> = []
    private var baseSize: CGFloat = 0
    private var secretValues: [String] = []
    private var palette: Aj38Palette?
    private var initialized = false
    private var iconResourceRevision: UInt64 = 0
    private var tailBlock: NSTextBlock?
    /// Work performed by the most recent render, independent of machine speed.
    private(set) var lastFormattedMessageCount = 0

    /// The transcript body may be revisited for a composer edit even when its
    /// document is unchanged. Keep the long, already-redacted AX value until
    /// either the document or its short scroll/status suffix changes.
    func accessibilityValue(status: String) -> String {
        if let cachedAccessibilityValue,
           cachedAccessibilityValue.revision == update.revision,
           cachedAccessibilityValue.status == status {
            return cachedAccessibilityValue.value
        }
        let value = accessibilityText + status
        cachedAccessibilityValue = (update.revision, status, value)
        accessibilityValueBuildCount += 1
        return value
    }

    /// Route text lives in assistant content. A draft-only view refresh must
    /// not search a large, unchanged transcript for the AX suffix again.
    func fallbackRouteStatus(compute: () -> String?) -> String? {
        if let cachedFallbackRouteStatus,
           cachedFallbackRouteStatus.revision == update.revision {
            return cachedFallbackRouteStatus.value
        }
        let value = compute()
        cachedFallbackRouteStatus = (update.revision, value)
        fallbackRouteCheckCount += 1
        return value
    }

    private func formatMessage(_ message: ChatMessageUI, baseSize: CGFloat,
                               redactor: ChatTranscriptRedactor,
                               palette: Aj38Palette?,
                               reuseTailBlock: Bool = false) -> NSAttributedString {
        lastFormattedMessageCount += 1
        let block = reuseTailBlock ? (tailBlock ?? NSTextBlock()) : NSTextBlock()
        tailBlock = block
        return ChatTranscriptFormatter.formattedMessage(
            message, baseSize: baseSize, redactor: redactor, palette: palette,
            block: block, inlineTools: inlineToolGaps[message.id] ?? []
        )
    }

    private var anchorStorage: NSTextStorage?
    private var anchorLayoutManager: NSLayoutManager?
    private var anchorContainer: NSTextContainer?
    private var anchorWidth: CGFloat = -1
    private var anchorOffsets: [CGFloat] = []
    private var inlineOffsetCache: (revision: UInt64, width: CGFloat, offsets: [String: CGFloat])?
    private var inlineIDCache: (revision: UInt64, ids: Set<String>)?

    @discardableResult
    func render(
        sessionID: UUID?, messages next: [ChatMessageUI], baseSize nextSize: CGFloat,
        redactor: ChatTranscriptRedactor, palette nextPalette: Aj38Palette? = nil,
        inlineTools nextInlineTools: [UUID: [ChatInlineToolGap]] = [:],
        expandedToolOutputIDs nextExpandedToolOutputIDs: Set<UUID> = []
    ) -> ChatTranscriptFormattedDocument {
        let scope = TranscriptOperationDiagnostics.nextScope(revision: update.revision &+ 1)
        return TranscriptOperationDiagnostics.$scope.withValue(scope) {
            renderScoped(sessionID: sessionID, messages: next, baseSize: nextSize,
                         redactor: redactor, palette: nextPalette, inlineTools: nextInlineTools,
                         expandedToolOutputIDs: nextExpandedToolOutputIDs)
        }
    }

    private func renderScoped(
        sessionID: UUID?, messages next: [ChatMessageUI], baseSize nextSize: CGFloat,
        redactor: ChatTranscriptRedactor, palette nextPalette: Aj38Palette?,
        inlineTools nextInlineTools: [UUID: [ChatInlineToolGap]],
        expandedToolOutputIDs nextExpandedToolOutputIDs: Set<UUID>
    ) -> ChatTranscriptFormattedDocument {
        let signpost = TranscriptPerformanceSignposts.signposter.beginInterval(
            TranscriptPerformanceSignposts.render
        )
        defer {
            TranscriptPerformanceSignposts.signposter.endInterval(
                TranscriptPerformanceSignposts.render, signpost
            )
        }
        lastFormattedMessageCount = 0
        let nextIconResourceRevision = ChatTranscriptStatusIconProjection.resourceRevision
        let samePolicy = initialized && self.sessionID == sessionID
            && baseSize == nextSize && secretValues == redactor.secretValues
            && palette == nextPalette
            && iconResourceRevision == nextIconResourceRevision
            && expandedToolOutputIDs == nextExpandedToolOutputIDs
        if samePolicy, messages == next, inlineToolGaps == nextInlineTools { return document }
        let previousInlineTools = inlineToolGaps
        inlineToolGaps = nextInlineTools

        let oldCount = messages.count
        let oldLength = document.attributedString.length
        let canReplaceTail = samePolicy && oldCount == next.count && oldCount > 0
            && messages.dropLast().elementsEqual(next.dropLast())
            && messages[oldCount - 1].id == next[oldCount - 1].id
            && messages[oldCount - 1].role == next[oldCount - 1].role
            && messages.dropLast().allSatisfy {
                previousInlineTools[$0.id] == nextInlineTools[$0.id]
            }
        // Sending can publish the user and empty assistant in the same frame.
        // Retain the whole unchanged prefix for any append batch.
        let canAppend = samePolicy && next.count > oldCount
            && messages.elementsEqual(next.prefix(oldCount))
            && messages.allSatisfy { previousInlineTools[$0.id] == nextInlineTools[$0.id] }

        if canReplaceTail || canAppend {
            let replacement: NSAttributedString
            let start: Int
            let accessibilityStart: Int
            let accessibilityReplacement: String
            var locations = document.messageStartLocations
            if canAppend {
                start = oldLength
                let suffix = NSMutableAttributedString(string: "")
                var accessibilitySuffix = ""
                for index in oldCount..<next.count {
                    let separator = index > 0 ? ChatTranscriptFormatter.separatorDocument() : NSAttributedString(string: "")
                    suffix.append(separator)
                    locations.append(start + suffix.length)
                    suffix.append(ChatTranscriptStatusIconProjection.prepare(formatMessage(
                        next[index], baseSize: nextSize, redactor: redactor,
                        palette: nextPalette
                    ), palette: nextPalette))
                    accessibilitySuffix += (index > 0 ? "\n\n" : "")
                        + ChatTranscriptFormatter.accessibilityText([next[index]], redactor: redactor)
                }
                replacement = suffix
                accessibilityStart = accessibleText.length
                accessibilityReplacement = accessibilitySuffix
            } else {
                start = locations[oldCount - 1]
                replacement = ChatTranscriptStatusIconProjection.prepare(
                    formatMessage(
                        next[oldCount - 1], baseSize: nextSize, redactor: redactor,
                        palette: nextPalette, reuseTailBlock: true
                    ), palette: nextPalette
                )
                accessibilityStart = accessibleText.length - accessibilityTailLength
                accessibilityReplacement = ChatTranscriptFormatter.accessibilityText([next[oldCount - 1]], redactor: redactor)
            }
            // SwiftUI can skip several streaming revisions before applying a
            // single update. Keep the replacement rooted at the message
            // anchor so the final patch can replay against any earlier tail
            // with the same stable history, including a shorter empty tail.
            // An equal prefix of the immediately previous tail is not enough
            // to prove equality with the native consumer's older storage.
            let updateStart = start
            let updateReplacement = replacement
            // The in-process document and anchor storage are on the exact
            // previous revision, so their equal attributed prefix can still
            // be retained even though the published patch must be replayable
            // against a native consumer that missed intermediate revisions.
            let oldTail = renderedText.attributedSubstring(from: NSRange(
                location: start, length: oldLength - start
            ))
            let retainedLength = canReplaceTail
                ? Self.unchangedAttributedPrefixLength(oldTail, replacement)
                : 0
            let mutationStart = start + retainedLength
            let mutationReplacement = retainedLength > 0
                ? replacement.attributedSubstring(from: NSRange(
                    location: retainedLength, length: replacement.length - retainedLength
                ))
                : replacement
            renderedText.replaceCharacters(
                in: NSRange(location: mutationStart, length: oldLength - mutationStart),
                with: mutationReplacement
            )
            document = ChatTranscriptFormattedDocument(
                attributedString: renderedText, messageStartLocations: locations
            )
            accessibleText.replaceCharacters(
                in: NSRange(location: accessibilityStart, length: accessibleText.length - accessibilityStart),
                with: accessibilityReplacement
            )
            accessibilityTailLength = canAppend
                ? (ChatTranscriptFormatter.accessibilityText([next[next.count - 1]], redactor: redactor) as NSString).length
                : (accessibilityReplacement as NSString).length
            accessibilityText = accessibleText as String
            if let anchorStorage {
                TranscriptOperationDiagnostics.textStorageEdit(
                    scope: TranscriptOperationDiagnostics.scope,
                    host: "anchor", mode: "tailReplace", start: mutationStart,
                    removed: oldLength - mutationStart,
                    inserted: mutationReplacement.length, oldLength: anchorStorage.length
                )
                anchorStorage.replaceCharacters(
                    in: NSRange(location: mutationStart, length: oldLength - mutationStart),
                    with: mutationReplacement
                )
            }
            update = ChatTranscriptStorageUpdate(
                revision: update.revision &+ 1,
                generation: update.generation,
                replacementStart: updateStart,
                replacement: updateReplacement,
                baseRevision: update.revision,
                exactBaseReplacementStart: canReplaceTail ? mutationStart : nil,
                exactBaseReplacement: canReplaceTail ? mutationReplacement : nil,
                diagnosticScope: TranscriptOperationDiagnostics.scope
            )
        } else {
            renderedText = NSMutableAttributedString(string: "")
            var locations: [Int] = []
            locations.reserveCapacity(next.count)
            // Match full rendering's construction order before sanitizing any
            // message. Keep offsets based on the sanitized, published lengths.
            let formatted = next.map { message in
                formatMessage(message, baseSize: nextSize, redactor: redactor, palette: nextPalette)
            }
            for (index, message) in formatted.enumerated() {
                if index > 0 {
                    renderedText.append(ReadOnlyAttributedTextView.sanitized(
                        ChatTranscriptFormatter.separatorDocument()
                    ))
                }
                locations.append(renderedText.length)
                renderedText.append(ChatTranscriptStatusIconProjection.prepare(message, palette: nextPalette))
            }
            document = ChatTranscriptFormattedDocument(
                attributedString: renderedText, messageStartLocations: locations
            )
            accessibilityText = ChatTranscriptFormatter.accessibilityText(next, redactor: redactor)
            accessibleText = NSMutableString(string: accessibilityText)
            accessibilityTailLength = next.last.map {
                (ChatTranscriptFormatter.accessibilityText([$0], redactor: redactor) as NSString).length
            } ?? 0
            anchorStorage = nil
            anchorLayoutManager = nil
            anchorContainer = nil
            anchorWidth = -1
            anchorOffsets.removeAll()
            update = ChatTranscriptStorageUpdate(
                revision: update.revision &+ 1,
                generation: update.generation &+ 1,
                replacementStart: nil,
                replacement: nil,
                diagnosticScope: TranscriptOperationDiagnostics.scope
            )
        }
        self.sessionID = sessionID
        expandedToolOutputIDs = nextExpandedToolOutputIDs
        messages = next
        baseSize = nextSize
        secretValues = redactor.secretValues
        palette = nextPalette
        initialized = true
        iconResourceRevision = nextIconResourceRevision
        return document
    }

    /// NSTextStorage ranges use UTF-16; never cut through a composed character
    /// or accept visually equal text with different UTF-16 bytes. Comparing the
    /// attributed prefix also covers fonts, paragraph layout and role blocks.
    private static func unchangedAttributedPrefixLength(
        _ old: NSAttributedString, _ next: NSAttributedString
    ) -> Int {
        let oldText = old.string as NSString
        let nextText = next.string as NSString
        let limit = min(oldText.length, nextText.length)
        var textLength = 0
        while textLength < limit,
              oldText.character(at: textLength) == nextText.character(at: textLength) {
            textLength += 1
        }
        var length = 0
        while length < textLength {
            var oldRun = NSRange()
            var nextRun = NSRange()
            let oldAttributes = old.attributes(at: length, effectiveRange: &oldRun)
            let nextAttributes = next.attributes(at: length, effectiveRange: &nextRun)
            guard NSDictionary(dictionary: oldAttributes).isEqual(to: nextAttributes) else { break }
            length = min(textLength, NSMaxRange(oldRun), NSMaxRange(nextRun))
        }
        // A changed run or UTF-16 unit may fall inside an emoji/combining cluster.
        // Retain only a boundary valid in both complete strings.
        while length > 0 {
            let oldBoundary = length < oldText.length
                ? oldText.rangeOfComposedCharacterSequence(at: length).location : length
            let nextBoundary = length < nextText.length
                ? nextText.rangeOfComposedCharacterSequence(at: length).location : length
            let boundary = min(length, oldBoundary, nextBoundary)
            if boundary == length { break }
            length = boundary
        }
        return length
    }

    /// TextKit retains layout before a changed tail. Anchor geometry is
    /// recomputed only for a new message or a width/structural change.
    func messageOffsets(contentWidth: CGFloat) -> [CGFloat] {
        let width = max(1, contentWidth)
        if abs(anchorWidth - width) >= 0.5 || anchorStorage == nil {
            let storage = NSTextStorage(attributedString: document.attributedString)
            let manager = NSLayoutManager()
            let container = NSTextContainer(
                containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            anchorStorage = storage
            anchorLayoutManager = manager
            anchorContainer = container
            anchorWidth = width
            anchorOffsets.removeAll()
        }
        if anchorOffsets.count == document.messageStartLocations.count { return anchorOffsets }
        guard let manager = anchorLayoutManager, let container = anchorContainer else { return [] }
        let firstNewAnchor = anchorOffsets.count
        for location in document.messageStartLocations.dropFirst(firstNewAnchor) {
            guard location < document.attributedString.length else {
                anchorOffsets.append(0)
                continue
            }
            TranscriptOperationDiagnostics.layoutRequest(
                scope: update.diagnosticScope, host: "anchor", mode: "suffix",
                start: location, length: 1,
                documentLength: document.attributedString.length
            )
            // The anchor consumes only this starting glyph. TextKit still
            // lays out any preceding paragraphs needed to determine its Y.
            manager.ensureLayout(forCharacterRange: NSRange(location: location, length: 1))
            let glyphRange = manager.glyphRange(
                forCharacterRange: NSRange(location: location, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else {
                anchorOffsets.append(0)
                continue
            }
            anchorOffsets.append(max(0, manager.boundingRect(forGlyphRange: glyphRange, in: container).minY))
        }
        return anchorOffsets
    }
    func inlineToolMarkerIDs() -> Set<String> {
        if let cached = inlineIDCache, cached.revision == update.revision { return cached.ids }
        let ids = ChatTranscriptInlineTools.renderedIDs(in: document.attributedString)
        inlineIDCache = (update.revision, ids)
        return ids
    }

    func inlineToolOffsets(contentWidth: CGFloat) -> [String: CGFloat] {
        // No String marker means there can be no inline offsets. In particular,
        // do not lay out an unmarked table merely to return an empty dictionary.
        guard !inlineToolMarkerIDs().isEmpty else { return [:] }
        let width = max(1, contentWidth)
        if let cached = inlineOffsetCache, cached.revision == update.revision,
           abs(cached.width - width) < 0.5 { return cached.offsets }
        _ = messageOffsets(contentWidth: width)
        guard let storage = anchorStorage, let manager = anchorLayoutManager else { return [:] }
        var offsets: [String: CGFloat] = [:]
        storage.enumerateAttribute(ChatInlineToolGap.marker,
            in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let id = value as? String else { return }
            manager.ensureLayout(forCharacterRange: range)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            offsets[id] = max(0, manager.lineFragmentRect(forGlyphAt: glyphs.location,
                                                        effectiveRange: nil).minY)
        }
        inlineOffsetCache = (update.revision, width, offsets)
        return offsets
    }
}

enum ChatTranscriptFormatter {
    /// Convert UI messages into the persistence DTO. Attachments are reduced
    /// to display text (never bytes, paths, or injected source content), then
    /// redacted once more at the persistence boundary.
    static func persistedEntries(
        _ messages: [ChatMessageUI],
        redactor: ChatTranscriptRedactor? = nil
    ) -> [ChatTranscriptEntry] {
        messages.map { message in
            let role = ChatTranscriptEntryRole(rawValue: message.role.rawValue) ?? .assistant
            let entry = ChatTranscriptEntry(role: role, text: bodyText(message, redactor: redactor))
            return redactor?.redact(entry) ?? entry
        }
    }

    /// Format one raw provider response before it can enter a transcript or
    /// draft. This is intentionally a small named seam for stream consumers.
    static func redactedRawResponse(
        _ response: String,
        redactor: ChatTranscriptRedactor
    ) -> String {
        redactor.redactRawResponse(response)
    }

    static func plainText(_ messages: [ChatMessageUI], redactor: ChatTranscriptRedactor? = nil) -> String {
        messages.map { message in
            let body = bodyText(message, redactor: redactor)
            return body.isEmpty
                ? "【\(roleLabel(message.role))】"
                : "【\(roleLabel(message.role))】\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// 统一转录视图的富文本数据源。所有消息仍合并在一个 NSTextView 中，
    /// 保留跨消息拖选和 ⌘A；可见角色标题与逐消息背景跟随同一份富文本。
    static func attributedString(
        _ messages: [ChatMessageUI], baseSize: CGFloat = 13,
        redactor: ChatTranscriptRedactor? = nil, palette: Aj38Palette? = nil
    ) -> NSAttributedString {
        formattedDocument(
            messages, baseSize: baseSize, redactor: redactor, palette: palette
        ).attributedString
    }

    /// Build the transcript and its message anchor locations in one pass.
    ///
    /// `ChatTranscriptView.messageAnchors` used to format `messages.prefix(i)`
    /// for every message. That made laying out a 50k/100k transcript quadratic,
    /// and the same work repeated whenever a streamed tail delta invalidated
    /// the view. Keeping the offsets beside the document preserves exact
    /// character positions while making the pass linear.
    static func formattedDocument(
        _ messages: [ChatMessageUI],
        baseSize: CGFloat = 13,
        redactor: ChatTranscriptRedactor? = nil,
        palette: Aj38Palette? = nil
    ) -> ChatTranscriptFormattedDocument {
        let result = NSMutableAttributedString()
        var messageStartLocations: [Int] = []
        messageStartLocations.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            if index > 0 {
                result.append(separatorDocument())
            }

            messageStartLocations.append(result.length)

            result.append(ChatTranscriptStatusIconProjection.prepare(formattedMessage(
                message, baseSize: baseSize, redactor: redactor, palette: palette
            ), palette: palette))
        }

        return ChatTranscriptFormattedDocument(
            attributedString: result,
            messageStartLocations: messageStartLocations
        )
    }

    static func separatorDocument() -> NSAttributedString {
        NSAttributedString(
            string: "\n\n", attributes: [.paragraphStyle: separatorParagraphStyle()]
        )
    }

    /// View-only projection. The transcript owner retains the original message
    /// for copy, export and Provider history; only actual tool roles collapse.
    static func toolOutputDisplayMessage(_ message: ChatMessageUI, expanded: Bool) -> ChatMessageUI {
        guard message.role == .tool, !expanded else { return message }
        var display = message
        let summary = ToolOutputSummary.capture(toolName: "", output: message.content)
            .displaySuffix ?? "仅显示统计，结果正文未在此展示（该工具已真实执行并返回结果；正文按上下文策略未保留，需要时重新调用读取）"
        display.content = "工具输出已折叠。" + summary
        return display
    }

    static func formattedMessage(
        _ message: ChatMessageUI, baseSize: CGFloat,
        redactor: ChatTranscriptRedactor?, palette: Aj38Palette? = nil,
        block suppliedBlock: NSTextBlock? = nil,
        inlineTools: [ChatInlineToolGap] = []
    ) -> NSAttributedString {
        let body = visibleBodyText(message, redactor: redactor)
        let block = suppliedBlock ?? NSTextBlock()
        block.backgroundColor = roleBackgroundColor(message.role, palette: palette)
        let result = NSMutableAttributedString(attributedString: roleHeader(
            message.role, baseSize: baseSize, palette: palette, block: block
        ))
        let content: NSMutableAttributedString
        if !inlineTools.isEmpty, message.role == .assistant {
            content = inlineBody(message: message, body: body, gaps: inlineTools,
                baseSize: baseSize, color: palette.map { nsColor($0.textPrimary) } ?? .textColor,
                redactor: redactor)
            if body.isEmpty && message.isStreaming {
                content.append(streamingPlaceholderDocument(baseSize: baseSize, palette: palette))
            }
        } else if body.isEmpty {
            content = message.role == .assistant && message.isStreaming
                ? streamingPlaceholderDocument(baseSize: baseSize, palette: palette)
                : NSMutableAttributedString(string: "")
        } else {
            content = NSMutableAttributedString(attributedString: MarkdownAttributedTextBuilder.build(
                content: body, isMarkdown: true, baseSize: baseSize,
                baseColor: palette.map { nsColor($0.textPrimary) } ?? .textColor
            ))
        }
        if message.role == .tool {
            let pattern = "⟦U\\+[0-9A-F]{4,6}⟧"
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(location: 0, length: content.length)
                for match in expression.matches(in: content.string, range: range) {
                    content.addAttribute(.foregroundColor,
                        value: palette.map { nsColor($0.statusWarning) } ?? NSColor.systemOrange,
                        range: match.range)
                }
            }
        }
        applyReadingParagraphStyle(to: content, role: message.role, block: block)
        result.append(content)
        let metadata = presentationMetadata(for: message)
        if !metadata.isEmpty {
            let note = NSMutableAttributedString(string: "\n" + metadata.joined(separator: "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: max(9, baseSize - 2)),
                .foregroundColor: palette.map { nsColor($0.textSecondary) } ?? NSColor.secondaryLabelColor
            ])
            applyReadingParagraphStyle(to: note, role: message.role, block: block)
            result.append(note)
        }
        return result
    }

    /// Split only the already-redacted body, after proving that the producer
    /// boundary survives the whole-body redaction unchanged. A secret crossing
    /// a boundary must not be exposed by independently rendering raw fragments.
    private static func inlineBody(
        message: ChatMessageUI, body: String, gaps: [ChatInlineToolGap],
        baseSize: CGFloat, color: NSColor, redactor: ChatTranscriptRedactor?
    ) -> NSMutableAttributedString {
        let raw = bodyText(message, redactor: nil)
        let result = NSMutableAttributedString(string: "")
        var cursor = body.startIndex
        if message.displayContent.utf16.elementsEqual(message.content.utf16) {
            for gap in gaps.sorted(by: { $0.sourceUTF16Offset < $1.sourceUTF16Offset }) {
                guard let rawRange = Range(NSRange(location: 0, length: gap.sourceUTF16Offset), in: raw) else { continue }
                let prefix = String(raw[..<rawRange.upperBound])
                let suffix = String(raw[rawRange.upperBound...])
                let visiblePrefix = redactor?.redactVisibleConversationBody(prefix) ?? prefix
                let visibleSuffix = redactor?.redactVisibleConversationBody(suffix) ?? suffix
                guard (visiblePrefix + visibleSuffix).utf16.elementsEqual(body.utf16),
                      let visibleRange = Range(NSRange(location: 0, length: visiblePrefix.utf16.count), in: body),
                      visibleRange.upperBound >= cursor else { continue }
                let segment = String(body[cursor..<visibleRange.upperBound])
                if !segment.isEmpty {
                    result.append(MarkdownAttributedTextBuilder.build(content: segment, isMarkdown: true,
                        baseSize: baseSize, baseColor: color))
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = gap.height
                paragraph.maximumLineHeight = gap.height
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: color,
                    .paragraphStyle: paragraph, ChatInlineToolGap.marker: gap.id
                ]))
                cursor = visibleRange.upperBound
            }
        }
        let remainder = String(body[cursor...])
        if !remainder.isEmpty {
            result.append(MarkdownAttributedTextBuilder.build(content: remainder, isMarkdown: true,
                baseSize: baseSize, baseColor: color))
        }
        return result
    }

    /// Presentation metadata must never enter persistedEntries or message-copy
    /// payloads. ChatStore owns the separate Codable interruption/count facts.
    private static func presentationMetadata(for message: ChatMessageUI) -> [String] {
        var metadata = message.wasInterrupted ? ["已中断"] : []
        metadata.append(contentsOf: message.attachments.compactMap {
            ComposerAttachmentPresentation.truncationNotice(for: $0, sent: true)
        })
        return metadata
    }

    /// 为单一 NSTextView 可访问元素提供角色边界；不读取可见样式或原始密文。
    static func accessibilityText(_ messages: [ChatMessageUI], redactor: ChatTranscriptRedactor? = nil) -> String {
        messages.map { message in
            let body = visibleBodyText(message, redactor: redactor)
            let metadata = presentationMetadata(for: message)
            let role = ([roleLabel(message.role)] + metadata).joined(separator: "，")
            if body.isEmpty {
                // D-CHAT-03：与可见转录同步，播报「生成中」状态。
                if message.role == .assistant, message.isStreaming {
                    return "\(role)：" + ChatTranscriptStatusIconProjection.accessibilityText(
                        NSAttributedString(string: streamingPlaceholder))
                }
                return role
            }
            let hasStatus = body.unicodeScalars.contains { "⏳⏹⚠❌✅🪄".unicodeScalars.contains($0) }
                && ChatTranscriptStatusIconProjection.hasStatus(inMarkdown: body)
            let spoken: String
            if hasStatus {
                let rich = MarkdownAttributedTextBuilder.build(content: body, isMarkdown: true)
                spoken = ChatTranscriptStatusIconProjection.hasStatus(in: rich)
                    ? ChatTranscriptStatusIconProjection.accessibilityText(rich) : body
            } else {
                spoken = body
            }
            return "\(role)：\(spoken)"
        }.joined(separator: "\n\n")
    }

    /// D-CHAT-03：流式空正文 assistant 消息的可见占位（仅渲染/无障碍层）。
    static let streamingPlaceholder = "⏳ 生成中…"

    private static func streamingPlaceholderDocument(baseSize: CGFloat, palette: Aj38Palette?) -> NSMutableAttributedString {
        NSMutableAttributedString(
            string: streamingPlaceholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: baseSize),
                .foregroundColor: palette.map { nsColor($0.textSecondary) } ?? NSColor.secondaryLabelColor,
            ]
        )
    }

    /// A shared text block keeps the role surface attached to the paragraphs of
    /// one message. The separator has no block; Markdown's glyph backgrounds stay
    /// on their original runs instead of being overwritten by a role fill.
    private static func roleHeader(
        _ role: ChatRole, baseSize: CGFloat, palette: Aj38Palette?, block: NSTextBlock
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment(for: role)
        style.firstLineHeadIndent = ChatReadingLayout.horizontalInset
        style.headIndent = ChatReadingLayout.horizontalInset
        // The user edit affordance overlays the first line at the trailing edge.
        // Its 18pt hit area plus a gap belongs to the header, not the body column.
        let editClearance: CGFloat = role == .user ? 44 + 8 : 20 + 8
        style.tailIndent = -(ChatReadingLayout.horizontalInset + editClearance)
        style.paragraphSpacingBefore = ChatReadingLayout.paragraphSpacingBefore
        style.paragraphSpacing = 0
        style.textBlocks = [block]
        let foreground: NSColor
        if let palette {
            let token = role == .user ? palette.accent : palette.textSecondary
            // The role fill is translucent over ChatSidebar's primary face.
            // Accent remains the graphical fill; this small readable title uses
            // the same secondary-text gate as other role headers.
            let fill = block.backgroundColor?.usingColorSpace(.sRGB)
            let alpha = Double(fill?.alphaComponent ?? 0)
            let background = ThemeColor(
                r: Double(fill?.redComponent ?? 0) * alpha + palette.backgroundPrimary.r * (1 - alpha),
                g: Double(fill?.greenComponent ?? 0) * alpha + palette.backgroundPrimary.g * (1 - alpha),
                b: Double(fill?.blueComponent ?? 0) * alpha + palette.backgroundPrimary.b * (1 - alpha))
            foreground = nsColor(ThemeContrast.foregroundMeetingContrast(
                token, role: .secondary, backgrounds: [background], readableAnchor: palette.textPrimary))
        } else {
            foreground = role == .user ? .controlAccentColor : .secondaryLabelColor
        }
        return NSAttributedString(
            string: "\(roleLabel(role))\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(11, baseSize * 0.85), weight: .semibold),
                .foregroundColor: foreground,
                .paragraphStyle: style,
            ]
        )
    }

    private static func roleBackgroundColor(_ role: ChatRole, palette: Aj38Palette?) -> NSColor {
        if let palette {
            switch role {
            case .user: return nsColor(palette.accent).withAlphaComponent(0.16)
            case .assistant: return .clear
            case .tool: return nsColor(palette.backgroundSecondary).withAlphaComponent(0.78)
            case .system: return nsColor(palette.backgroundSecondary).withAlphaComponent(0.55)
            }
        }
        switch role {
        case .user: return NSColor.controlAccentColor.withAlphaComponent(0.16)
        case .assistant: return .clear
        case .tool: return NSColor.controlBackgroundColor.withAlphaComponent(0.78)
        case .system: return NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        }
    }

    private static func nsColor(_ color: ThemeColor) -> NSColor {
        NSColor(srgbRed: CGFloat(color.r), green: CGFloat(color.g),
                blue: CGFloat(color.b), alpha: 1)
    }

    private static func visibleBodyText(_ message: ChatMessageUI, redactor: ChatTranscriptRedactor?) -> String {
        guard message.role == .tool else { return bodyText(message, redactor: redactor) }
        // Redact raw text before projection so inserting a marker cannot split
        // a known-value redaction match. Hidden outputs retain their boundary.
        if message.content.count > ProductRedactionPolicy.maxTranscriptFieldLength {
            let markers = InvisibleCharacterPolicy.markerInventory(message.content)
            return bodyText(message, redactor: redactor)
                + (markers.isEmpty ? "" : "\n不可见字符：" + markers)
        }
        return InvisibleCharacterPolicy.visible(bodyText(message, redactor: redactor))
    }

    private static func bodyText(_ message: ChatMessageUI, redactor: ChatTranscriptRedactor? = nil) -> String {
        var lines: [String] = []
        if !message.displayContent.isEmpty {
            lines.append(message.displayContent)
        }
        lines.append(contentsOf: message.attachments.map { "附件：\($0.fileName)" })
        let body = lines.joined(separator: "\n")
        // S2：内容级脱敏接缝 —— 三条转录表面（plainText / attributedString /
        // accessibilityText）共用此出口，secret 值在到达输出前统一掩码。
        guard let redactor else { return body }
        switch message.role {
        case .user, .assistant:
            TranscriptOperationDiagnostics.redactorCall(mode: "visible")
            return redactor.redactVisibleConversationBody(body)
        case .tool, .system:
            TranscriptOperationDiagnostics.redactorCall(mode: "bounded")
            return redactor.redact(body)
        }
    }

    /// Apply the shared reading column without replacing inline/block attributes.
    /// A single NSTextView remains the selection/copy seam for the full transcript.
    private static func applyReadingParagraphStyle(
        to body: NSMutableAttributedString,
        role: ChatRole, block: NSTextBlock
    ) {
        guard body.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: body.length)
        var ranges: [(range: NSRange, original: NSParagraphStyle?)] = []
        body.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            ranges.append((range, value as? NSParagraphStyle))
        }

        for entry in ranges {
            let style = (entry.original?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            // Cells keep their native hierarchy: an ordinary role block must
            // never wrap the table. Put the reading gutter on its outer cells,
            // outside their existing padding, instead of in each text indent.
            let cells = style.textBlocks.compactMap { $0 as? NSTextTableBlock }
            if !cells.isEmpty {
                let gutter = max(0, ChatReadingLayout.horizontalInset - ChatReadingLayout.tablePadding)
                for cell in cells {
                    if cell.startingColumn == 0 {
                        cell.setWidth(gutter, type: .absoluteValueType, for: .margin, edge: .minX)
                    }
                    if cell.startingColumn + cell.columnSpan == cell.table.numberOfColumns {
                        cell.setWidth(gutter, type: .absoluteValueType, for: .margin, edge: .maxX)
                    }
                    if cell.startingRow == 0 {
                        cell.setWidth(ChatReadingLayout.blockSpacing,
                                      type: .absoluteValueType, for: .margin, edge: .minY)
                    }
                }
                style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, ChatReadingLayout.paragraphSpacingBefore)
                style.paragraphSpacing = max(style.paragraphSpacing, ChatReadingLayout.paragraphSpacing)
                style.lineSpacing = max(style.lineSpacing, ChatReadingLayout.lineSpacing)
                body.addAttribute(.paragraphStyle, value: style, range: entry.range)
                continue
            }
            let isCodeBlock = !style.textBlocks.isEmpty
            if isCodeBlock {
                style.paragraphSpacingBefore = 0
                style.paragraphSpacing = 0
                style.lineSpacing = 0
            }
            let existingFirstLineInset = max(0, style.firstLineHeadIndent)
            let existingBlockInset = max(0, style.headIndent)
            let existingTrailingInset = min(0, style.tailIndent)

            style.firstLineHeadIndent = ChatReadingLayout.horizontalInset + existingFirstLineInset
            style.headIndent = ChatReadingLayout.horizontalInset + existingBlockInset
            style.tailIndent = -ChatReadingLayout.horizontalInset + existingTrailingInset
            if !isCodeBlock {
                style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, ChatReadingLayout.paragraphSpacingBefore)
                style.paragraphSpacing = max(style.paragraphSpacing, ChatReadingLayout.paragraphSpacing)
                style.lineSpacing = max(style.lineSpacing, ChatReadingLayout.lineSpacing)
            }
            style.alignment = alignment(for: role)
            style.textBlocks = [block] + style.textBlocks

            body.addAttribute(
                .paragraphStyle,
                value: style,
                range: entry.range
            )
        }
    }

    private static func alignment(for role: ChatRole) -> NSTextAlignment {
        switch role {
        case .user: return .right
        case .assistant: return .left
        case .tool: return .left
        case .system: return .center
        }
    }

    private static func separatorParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 0
        return style
    }

    private static func roleLabel(_ role: ChatRole) -> String {
        switch role {
        case .user: return "用户"
        case .assistant: return "助手"
        case .tool: return "工具"
        case .system: return "系统"
        }
    }
}
