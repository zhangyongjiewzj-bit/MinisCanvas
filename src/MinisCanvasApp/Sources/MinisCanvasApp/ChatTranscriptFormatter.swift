import Foundation
import SwiftUI
import AppKit
import ImageIO
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

/// 展示投影缓存（折叠工具输出、展开思考）。投影只对折叠的工具消息与展开思考的
/// 助手消息产生新值，其余原样返回；折叠摘要要逐字节统计换行，所以按
/// （消息值 + 两个展开标记）缓存，body 重算时不再重复扫描 MB 级工具输出。
final class ChatTranscriptDisplayProjectionCache {
    private struct Slot {
        let source: ChatMessageUI
        let toolExpanded: Bool
        let thinkingExpanded: Bool
        let display: ChatMessageUI
    }
    private var slots: [UUID: Slot] = [:]
    private var codeTitles: [UUID: (content: String, secrets: [String], titles: [String])] = [:]
    /// 真正重新投影的条数（测试与量化用）。
    private(set) var projectionBuildCount = 0

    func project(
        _ messages: [ChatMessageUI],
        toolExpanded: (UUID) -> Bool,
        thinkingExpanded: (UUID) -> Bool
    ) -> [ChatMessageUI] {
        var next: [UUID: Slot] = [:]
        let result = messages.map { message -> ChatMessageUI in
            let toolOpen = toolExpanded(message.id)
            let thinkingOpen = thinkingExpanded(message.id)
            let changesTool = message.role == .tool && !toolOpen
            let changesThinking = thinkingOpen && message.role == .assistant
                && message.thinkingText?.isEmpty == false
            guard changesTool || changesThinking else { return message }
            if let slot = slots[message.id], slot.toolExpanded == toolOpen,
               slot.thinkingExpanded == thinkingOpen, slot.source == message {
                next[message.id] = slot
                return slot.display
            }
            projectionBuildCount += 1
            let display = ChatTranscriptFormatter.thinkingDisplayMessage(
                ChatTranscriptFormatter.toolOutputDisplayMessage(message, expanded: toolOpen),
                expanded: thinkingOpen)
            next[message.id] = Slot(source: message, toolExpanded: toolOpen,
                                    thinkingExpanded: thinkingOpen, display: display)
            return display
        }
        slots = next
        return result
    }

    /// 代码块菜单标题：解析整条消息的 Markdown 不便宜，按（正文 + 脱敏值）缓存。
    func codeBlockMenuTitles(messageID: UUID, content: String, secrets: [String],
                             compute: () -> [String]) -> [String] {
        if let hit = codeTitles[messageID], hit.content == content, hit.secrets == secrets {
            return hit.titles
        }
        let titles = compute()
        if codeTitles.count > 500 { codeTitles.removeAll() }
        codeTitles[messageID] = (content, secrets, titles)
        return titles
    }

    /// 锚点按 id 查消息：替代每个锚点两次 `first(where:)`；重复 id 取第一条，与原行为一致。
    static func index(_ messages: [ChatMessageUI]) -> [UUID: ChatMessageUI] {
        Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// 消息级格式化缓存：键 = 消息 id；命中须同时满足消息内容（含展开投影后的正文）、
/// 内联工具间隙、字号、脱敏值、主题、状态图标资源修订全部相同。
/// 跨会话切换复用未变消息；按总字符数与条数做最近最少使用淘汰。
/// 流式中的消息不入缓存。注意：文件路径链接的"是否存在"在入缓存时定格，
/// 直到该消息内容或渲染参数变化才重算。
final class ChatTranscriptFormatStore: @unchecked Sendable {
    static let shared = ChatTranscriptFormatStore()

    struct Entry {
        let message: ChatMessageUI
        let gaps: [ChatInlineToolGap]
        let baseSize: CGFloat
        let secretValues: [String]
        let palette: Aj38Palette?
        let iconRevision: UInt64
        let prepared: NSAttributedString
        let block: NSTextBlock
        let accessibility: String
    }

    private struct Slot {
        let entry: Entry
        let cost: Int
        var lastUse: UInt64
    }

    static let maxCost = 6_000_000
    static let maxCount = 3_000

    private let lock = NSLock()
    private var slots: [UUID: Slot] = [:]
    private var totalCost = 0
    private var tick: UInt64 = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return slots.count }

    func lookup(message: ChatMessageUI, gaps: [ChatInlineToolGap], baseSize: CGFloat,
                secretValues: [String], palette: Aj38Palette?, iconRevision: UInt64) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard var slot = slots[message.id] else { return nil }
        let entry = slot.entry
        guard entry.baseSize == baseSize, entry.iconRevision == iconRevision,
              entry.gaps == gaps, entry.secretValues == secretValues,
              entry.palette == palette, entry.message == message else { return nil }
        tick &+= 1
        slot.lastUse = tick
        slots[message.id] = slot
        return entry
    }

    func store(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        let cost = entry.prepared.length + entry.accessibility.utf16.count
        if let old = slots[entry.message.id] { totalCost -= old.cost }
        tick &+= 1
        slots[entry.message.id] = Slot(entry: entry, cost: cost, lastUse: tick)
        totalCost += cost
        guard totalCost > Self.maxCost || slots.count > Self.maxCount else { return }
        let targetCost = Self.maxCost * 3 / 4
        let targetCount = Self.maxCount * 3 / 4
        for (id, slot) in slots.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            if totalCost <= targetCost && slots.count <= targetCount { break }
            slots[id] = nil
            totalCost -= slot.cost
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        slots.removeAll(); totalCost = 0
    }
}

/// 首开预热：空闲时为最近会话预先填充消息级格式化缓存。
/// 输入必须与真实视图一致才会命中：字号、调色板、脱敏值、状态图标修订、展开状态（默认折叠）、
/// 展示投影（同一个 `ChatTranscriptDisplayProjectionCache`）。内联工具间隙依赖视图测量，预热按空处理，
/// 有内联工具的助手消息因此不会命中（照常现算，不劣化）。路径链接是否存在取决于项目根，
/// 逐会话临时设置 `TranscriptPathLinkContext` 并立即还原（无 await，不会被真实渲染看到）。
@MainActor
enum ChatTranscriptPrewarmer {
    struct Target {
        let messages: [ChatMessageUI]
        let projectRoot: URL?
    }

    /// 返回真正重新格式化的消息数。每处理完一条若本批耗时超过 `batchBudget` 就让出主线程。
    @discardableResult
    static func prewarm(
        targets: [Target], baseSize: CGFloat, redactor: ChatTranscriptRedactor,
        palette: Aj38Palette?, iconRevision: UInt64,
        store: ChatTranscriptFormatStore = .shared,
        batchBudget: Duration = .milliseconds(8),
        shouldContinue: () -> Bool = { true }
    ) async -> Int {
        let cache = ChatTranscriptDocumentCache(formatStore: store)
        let projection = ChatTranscriptDisplayProjectionCache()
        let clock = ContinuousClock()
        var batchStart = clock.now
        var fresh = 0
        for target in targets {
            let display = projection.project(
                target.messages, toolExpanded: { _ in false }, thinkingExpanded: { _ in false })
            for message in display {
                guard !Task.isCancelled, shouldContinue() else { return fresh }
                let context = TranscriptPathLinkContext.shared
                let savedRoot = context.projectRoot
                context.projectRoot = target.projectRoot
                if cache.prewarm(message, baseSize: baseSize, redactor: redactor,
                                 palette: palette, iconRevision: iconRevision) {
                    fresh += 1
                }
                context.projectRoot = savedRoot
                if clock.now - batchStart >= batchBudget {
                    await Task.yield()
                    batchStart = clock.now
                }
            }
        }
        return fresh
    }
}

/// 显示层（第二道保险）对流式助手消息的增量脱敏。
///
/// 结果必须与 `ChatTranscriptRedactor.redactVisibleConversationBody(body)` 逐字节一致：
/// 用 MinisCore 的 `IncrementalSecretRedactor` 维护已提交前缀（以换行结尾，之后不再重扫）与尾部，
/// 每片段只重扫新增尾部；"遮蔽带凭据链接"这一步链接匹配不含空白，所以对已提交前缀只在新增的
/// 那一段上做、其结果累加。以下情况退回全量重建：消息 id 首次出现、内容不是在上次文本后追加
/// （替换/截断）、脱敏值集合变化。消息结束（非流式）时由 `finish` 释放状态，终态走原来的全量脱敏。
final class StreamingDisplayRedactionCache {
    private struct State {
        var incremental: IncrementalSecretRedactor
        let secrets: [String]
        /// 已做过链接遮蔽的已提交前缀（原文）及其结果。
        var linkedSource: String
        var linkedResult: String
    }

    private var states: [UUID: State] = [:]
    private static let maxStates = 8
    /// 复用已有状态只扫新增部分的次数 / 整体重建的次数（测试与量化用）。
    private(set) var incrementalCount = 0
    private(set) var rebuildCount = 0
    var trackedCount: Int { states.count }

    func redactedBody(messageID: UUID, body: String, secrets: [String]) -> String {
        var state: State
        if var existing = states.removeValue(forKey: messageID), existing.secrets == secrets,
           Self.hasUTF8Prefix(body, existing.incremental.rawText) {
            let known = existing.incremental.rawText.utf8.count
            if body.utf8.count > known {
                let delta = String(decoding: Array(body.utf8.dropFirst(known)), as: UTF8.self)
                _ = existing.incremental.append(delta, knownSecrets: secrets)
            }
            incrementalCount += 1
            state = existing
        } else {
            if states.count >= Self.maxStates { states.removeAll() }
            var incremental = IncrementalSecretRedactor()
            _ = incremental.append(body, knownSecrets: secrets)
            rebuildCount += 1
            state = State(incremental: incremental, secrets: secrets, linkedSource: "", linkedResult: "")
        }
        let committed = state.incremental.committedText
        let previousCount = state.linkedSource.utf8.count
        let splitIsSafe = previousCount == 0 || state.linkedSource.utf8.last == 0x0A
        if splitIsSafe, committed.utf8.count >= previousCount,
           Self.hasUTF8Prefix(committed, state.linkedSource) {
            if committed.utf8.count > previousCount {
                let added = String(decoding: Array(committed.utf8.dropFirst(previousCount)), as: UTF8.self)
                state.linkedResult += ProductRedactionPolicy.maskCredentialLinks(
                    inRedacted: added, knownSecrets: secrets)
            }
        } else {
            state.linkedResult = ProductRedactionPolicy.maskCredentialLinks(
                inRedacted: committed, knownSecrets: secrets)
        }
        state.linkedSource = committed
        let tail = ProductRedactionPolicy.maskCredentialLinks(
            inRedacted: state.incremental.settledTailProjection(knownSecrets: secrets),
            knownSecrets: secrets)
        let result = state.linkedResult + tail
        states[messageID] = state
        return result
    }

    func finish(messageID: UUID) {
        states.removeValue(forKey: messageID)
    }

    func removeAll() { states.removeAll() }

    /// 字节级前缀比较（memcmp），比逐元素迭代 UTF8View 快得多（调试构建尤其明显）。
    private static func hasUTF8Prefix(_ whole: String, _ prefix: String) -> Bool {
        var whole = whole, prefix = prefix
        return whole.withUTF8 { wholeBytes in
            prefix.withUTF8 { prefixBytes in
                guard prefixBytes.count <= wholeBytes.count else { return false }
                guard prefixBytes.count > 0 else { return true }
                return memcmp(wholeBytes.baseAddress!, prefixBytes.baseAddress!, prefixBytes.count) == 0
            }
        }
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
    private var accessibilityStringCache: (revision: UInt64, value: String)?
    /// 惰性桥接：流式每片段只改 accessibleText，整串 String 在被读取时才生成。
    var accessibilityText: String {
        if let accessibilityStringCache, accessibilityStringCache.revision == update.revision {
            return accessibilityStringCache.value
        }
        let value = accessibleText as String
        accessibilityStringCache = (update.revision, value)
        return value
    }
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
    /// 其中命中消息级缓存的条数与真正重新格式化的条数。
    private(set) var lastCacheHitCount = 0
    private(set) var lastFreshlyFormattedCount = 0
    private let formatStore: ChatTranscriptFormatStore
    /// 本文档独占的 Markdown 块缓存（流式尾消息只重建变化的最后一块）。
    let blockCache = MarkdownBlockRenderCache()
    /// 流式助手消息的显示层增量脱敏状态（按消息 id；结束或非追加变化时释放/重建）。
    let streamRedaction = StreamingDisplayRedactionCache()

    init(formatStore: ChatTranscriptFormatStore = .shared) {
        self.formatStore = formatStore
    }

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

    /// 流式尾消息的增量加工状态。`checkpoints` 是升序的（原文偏移，已加工偏移）对：
    /// `prepared` 的 [0, 已加工偏移) 恰好是 `prepare(raw[0, 原文偏移))`。检查点总落在换行之后，
    /// 而 prepare 的清洗与状态图标匹配都按 run/字符局部计算（字素簇不跨换行），
    /// 所以分段加工与整段加工等价。每隔约 1500 字符记一个，前缀被改动时退回到最近的检查点。
    private struct StreamTail {
        let messageID: UUID
        let baseSize: CGFloat
        let palette: Aj38Palette?
        let iconRevision: UInt64
        let raw: NSAttributedString
        let prepared: NSMutableAttributedString
        let checkpoints: [(raw: Int, prepared: Int)]
    }
    private var streamTail: StreamTail?
    /// 最近一次 formatPart 直接复用的已加工前缀长度（相对该消息起点）；0 表示没有。
    private var lastReusedPreparedLength = 0
    /// 流式增量加工复用检查点的次数 / 重新整段加工的次数（测试与量化用）。
    private(set) var streamPrepareReuseCount = 0
    private(set) var streamPrepareRebuildCount = 0
    private static let streamCheckpointStride = 1500

    private func incrementallyPrepared(
        _ raw: NSAttributedString, messageID: UUID, baseSize: CGFloat,
        palette: Aj38Palette?, iconRevision: UInt64, mayReuse: Bool
    ) -> NSAttributedString {
        let working: NSMutableAttributedString
        var checkpoints: [(raw: Int, prepared: Int)] = []
        var rawStart = 0
        if mayReuse, let state = streamTail, state.messageID == messageID,
           state.baseSize == baseSize, state.palette == palette,
           state.iconRevision == iconRevision {
            let common = Self.unchangedAttributedPrefixLength(state.raw, raw)
            checkpoints = state.checkpoints.filter { $0.raw <= common }
        }
        if let keep = checkpoints.last, keep.raw > 0, let state = streamTail {
            working = state.prepared
            if working.length > keep.prepared {
                working.deleteCharacters(in: NSRange(
                    location: keep.prepared, length: working.length - keep.prepared))
            }
            rawStart = keep.raw
            lastReusedPreparedLength = keep.prepared
            streamPrepareReuseCount += 1
        } else {
            working = NSMutableAttributedString()
            checkpoints = []
            lastReusedPreparedLength = 0
            streamPrepareRebuildCount += 1
        }
        let rawText = raw.string as NSString
        // 块渲染会在末尾补空行，而流式时最后一块还在增长：检查点取"去掉末尾换行后
        // 的最后一行"之前，才不会落在下一个片段会插入文字的位置之后。
        var contentEnd = rawText.length
        while contentEnd > 0, rawText.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        let lastBreak = contentEnd > 0
            ? rawText.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: contentEnd))
            : NSRange(location: NSNotFound, length: 0)
        let limit = lastBreak.location != NSNotFound ? lastBreak.location + 1 : 0
        var position = rawStart
        while position < limit {
            let searchFrom = position + Self.streamCheckpointStride
            guard searchFrom < limit else { break }
            let next = rawText.range(of: "\n", options: [], range: NSRange(
                location: searchFrom, length: limit - searchFrom))
            guard next.location != NSNotFound else { break }
            let boundary = next.location + 1
            working.append(ChatTranscriptStatusIconProjection.prepare(
                raw.attributedSubstring(from: NSRange(location: position, length: boundary - position)),
                palette: palette))
            checkpoints.append((boundary, working.length))
            position = boundary
        }
        if raw.length > position {
            working.append(ChatTranscriptStatusIconProjection.prepare(
                raw.attributedSubstring(from: NSRange(location: position, length: raw.length - position)),
                palette: palette))
        }
        if checkpoints.first?.raw != 0 { checkpoints.insert((0, 0), at: 0) }
        streamTail = StreamTail(
            messageID: messageID, baseSize: baseSize, palette: palette, iconRevision: iconRevision,
            raw: raw, prepared: working, checkpoints: checkpoints)
        return NSAttributedString(attributedString: working)
    }

    /// 一条消息的最终产物：已做状态图标投影的富文本 + 无障碍文本。
    private struct FormattedPart {
        let prepared: NSAttributedString
        let accessibility: String
    }

    /// `lastFormattedMessageCount` 仍表示"本次渲染走过几条消息"（路径选择的度量，
    /// 命中缓存也计数）；真正重新格式化的条数在 `lastFreshlyFormattedCount`。
    private func formatPart(_ message: ChatMessageUI, baseSize: CGFloat,
                            redactor: ChatTranscriptRedactor,
                            palette: Aj38Palette?, iconRevision: UInt64,
                            reuseTailBlock: Bool = false) -> FormattedPart {
        lastFormattedMessageCount += 1
        let gaps = inlineToolGaps[message.id] ?? []
        let secrets = redactor.secretValues
        if !message.isStreaming,
           let hit = formatStore.lookup(
               message: message, gaps: gaps, baseSize: baseSize, secretValues: secrets,
               palette: palette, iconRevision: iconRevision) {
            tailBlock = hit.block
            lastCacheHitCount += 1
            streamTail = nil
            lastReusedPreparedLength = 0
            return FormattedPart(prepared: hit.prepared, accessibility: hit.accessibility)
        }
        lastFreshlyFormattedCount += 1
        lastReusedPreparedLength = 0
        let block: NSTextBlock
        if message.role == .user && !message.isBackgroundCompletionNotice {
            block = UserBubbleTextBlock()
        } else if reuseTailBlock, let reusable = tailBlock, !(reusable is UserBubbleTextBlock) {
            block = reusable
        } else {
            block = NSTextBlock()
        }
        tailBlock = block
        let formatted = ChatTranscriptFormatter.formattedMessageWithBody(
            message, baseSize: baseSize, redactor: redactor, palette: palette,
            block: block, inlineTools: gaps, blockCache: blockCache,
            streamRedaction: message.isStreaming ? streamRedaction : nil
        )
        if !message.isStreaming { streamRedaction.finish(messageID: message.id) }
        let prepared: NSAttributedString
        if message.isStreaming {
            prepared = incrementallyPrepared(
                formatted.attributed, messageID: message.id, baseSize: baseSize,
                palette: palette, iconRevision: iconRevision, mayReuse: reuseTailBlock)
        } else {
            streamTail = nil
            prepared = ChatTranscriptStatusIconProjection.prepare(formatted.attributed, palette: palette)
        }
        let accessibility = ChatTranscriptFormatter.accessibilityText(for: message, body: formatted.body)
        if !message.isStreaming {
            formatStore.store(ChatTranscriptFormatStore.Entry(
                message: message, gaps: gaps, baseSize: baseSize, secretValues: secrets,
                palette: palette, iconRevision: iconRevision, prepared: prepared,
                block: block, accessibility: accessibility))
        }
        return FormattedPart(prepared: prepared, accessibility: accessibility)
    }

    /// 预热：与真实渲染走同一条 `formatPart`，把一条已完成消息的格式化结果存进消息级缓存。
    /// 已命中则不重做。返回是否真的重新格式化。
    @discardableResult
    func prewarm(_ message: ChatMessageUI, baseSize: CGFloat, redactor: ChatTranscriptRedactor,
                 palette: Aj38Palette?, iconRevision: UInt64) -> Bool {
        guard !message.isStreaming else { return false }
        let before = lastFreshlyFormattedCount
        _ = formatPart(message, baseSize: baseSize, redactor: redactor,
                       palette: palette, iconRevision: iconRevision)
        return lastFreshlyFormattedCount > before
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
        lastCacheHitCount = 0
        lastFreshlyFormattedCount = 0
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
            var appendedLastAccessibilityLength = 0
            var locations = document.messageStartLocations
            if canAppend {
                start = oldLength
                let suffix = NSMutableAttributedString(string: "")
                var accessibilitySuffix = ""
                for index in oldCount..<next.count {
                    let separator = index > 0 ? ChatTranscriptFormatter.separatorDocument() : NSAttributedString(string: "")
                    suffix.append(separator)
                    locations.append(start + suffix.length)
                    let part = formatPart(
                        next[index], baseSize: nextSize, redactor: redactor,
                        palette: nextPalette, iconRevision: nextIconResourceRevision)
                    suffix.append(part.prepared)
                    accessibilitySuffix += (index > 0 ? "\n\n" : "") + part.accessibility
                    appendedLastAccessibilityLength = (part.accessibility as NSString).length
                }
                replacement = suffix
                accessibilityStart = accessibleText.length
                accessibilityReplacement = accessibilitySuffix
            } else {
                start = locations[oldCount - 1]
                let part = formatPart(
                    next[oldCount - 1], baseSize: nextSize, redactor: redactor,
                    palette: nextPalette, iconRevision: nextIconResourceRevision,
                    reuseTailBlock: true)
                replacement = part.prepared
                accessibilityStart = accessibleText.length - accessibilityTailLength
                accessibilityReplacement = part.accessibility
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
            // 流式尾消息：加工状态已证明前 `lastReusedPreparedLength` 个字符与上一版
            // 存储逐一相同，不必再取旧尾巴整段比较。
            let retainedLength: Int
            if canReplaceTail, lastReusedPreparedLength > 0,
               lastReusedPreparedLength <= replacement.length,
               start + lastReusedPreparedLength <= oldLength {
                // 检查点之后只剩最后一行左右：在这一小段里再找真正的首个差异，
                // 让补丁从实际改动处开始，原生文本视图只追加新内容（滚动更稳）。
                let known = lastReusedPreparedLength
                let oldRest = renderedText.attributedSubstring(from: NSRange(
                    location: start + known, length: oldLength - start - known))
                let newRest = replacement.attributedSubstring(from: NSRange(
                    location: known, length: replacement.length - known))
                retainedLength = known + Self.unchangedAttributedPrefixLength(oldRest, newRest)
            } else {
                let oldTail = renderedText.attributedSubstring(from: NSRange(
                    location: start, length: oldLength - start
                ))
                retainedLength = canReplaceTail
                    ? Self.unchangedAttributedPrefixLength(oldTail, replacement)
                    : 0
            }
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
                ? appendedLastAccessibilityLength
                : (accessibilityReplacement as NSString).length
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
            // Unchanged messages come from the message-level store, so toggling
            // one tool output or revisiting a session re-formats only what changed.
            let formatted = next.map { message in
                formatPart(message, baseSize: nextSize, redactor: redactor,
                           palette: nextPalette, iconRevision: nextIconResourceRevision)
            }
            let separator = ReadOnlyAttributedTextView.sanitized(
                ChatTranscriptFormatter.separatorDocument()
            )
            for (index, part) in formatted.enumerated() {
                if index > 0 {
                    renderedText.append(separator)
                }
                locations.append(renderedText.length)
                renderedText.append(part.prepared)
            }
            document = ChatTranscriptFormattedDocument(
                attributedString: renderedText, messageStartLocations: locations
            )
            accessibleText = NSMutableString(
                string: formatted.map(\.accessibility).joined(separator: "\n\n"))
            accessibilityTailLength = formatted.last.map {
                ($0.accessibility as NSString).length
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

    /// 属性字典相等；代码块每次重建都会新建一个外观相同的 NSTextBlock（对象不同），
    /// 逐值 isEqual 会让流式前缀在第一个代码块处就判为"已变"。这里只对段落样式里的
    /// 普通文本块（非表格单元）按外观（背景色与各层各边宽度）判等，其余仍用 isEqual。
    private static func attributesEquivalent(
        _ old: [NSAttributedString.Key: Any], _ next: [NSAttributedString.Key: Any]
    ) -> Bool {
        if attributeDictionariesEqual(old, next) { return true }
        guard old.count == next.count,
              let oldStyle = old[.paragraphStyle] as? NSParagraphStyle,
              let nextStyle = next[.paragraphStyle] as? NSParagraphStyle else { return false }
        var oldRest = old, nextRest = next
        oldRest.removeValue(forKey: .paragraphStyle)
        nextRest.removeValue(forKey: .paragraphStyle)
        guard attributeDictionariesEqual(oldRest, nextRest) else { return false }
        guard oldStyle.textBlocks.count == nextStyle.textBlocks.count,
              zip(oldStyle.textBlocks, nextStyle.textBlocks).contains(where: { $0 !== $1 }) else { return false }
        // 其余段落字段逐项相同，仅 textBlocks 的对象身份不同。
        let oldCopy = oldStyle.mutableCopy() as! NSMutableParagraphStyle
        let nextCopy = nextStyle.mutableCopy() as! NSMutableParagraphStyle
        oldCopy.textBlocks = []
        nextCopy.textBlocks = []
        guard oldCopy.isEqual(nextCopy) else { return false }
        return zip(oldStyle.textBlocks, nextStyle.textBlocks).allSatisfy { lhs, rhs in
            lhs === rhs || plainBlocksLookTheSame(lhs, rhs)
        }
    }

    /// 与 `NSDictionary(dictionary:).isEqual(to:)` 同口径（键集相同、逐值 isEqual），
    /// 但不把整个 Swift 字典桥接成 NSDictionary（采样中这是每片段前缀比较的最大开销）。
    private static func attributeDictionariesEqual(
        _ old: [NSAttributedString.Key: Any], _ next: [NSAttributedString.Key: Any]
    ) -> Bool {
        guard old.count == next.count else { return false }
        for (key, oldValue) in old {
            guard let nextValue = next[key] else { return false }
            let lhs = oldValue as AnyObject, rhs = nextValue as AnyObject
            if lhs !== rhs, !lhs.isEqual(rhs) { return false }
        }
        return true
    }

    private static func plainBlocksLookTheSame(_ lhs: NSTextBlock, _ rhs: NSTextBlock) -> Bool {
        // 普通文本块与代码卡片块（CodeSurfaceTextBlock）都按外观判等；表格单元等其他子类不在此列。
        guard type(of: lhs) == type(of: rhs),
              type(of: lhs) == NSTextBlock.self || type(of: lhs) == CodeSurfaceTextBlock.self
                  || type(of: lhs) == UserBubbleTextBlock.self,
              lhs.backgroundColor == rhs.backgroundColor,
              lhs.borderColor(for: .minX) == rhs.borderColor(for: .minX),
              lhs.verticalAlignment == rhs.verticalAlignment else { return false }
        for layer in [NSTextBlock.Layer.padding, .border, .margin] {
            for edge in [NSRectEdge.minX, .minY, .maxX, .maxY] {
                guard lhs.width(for: layer, edge: edge) == rhs.width(for: layer, edge: edge),
                      lhs.widthValueType(for: layer, edge: edge) == rhs.widthValueType(for: layer, edge: edge)
                else { return false }
            }
        }
        return lhs.contentWidth == rhs.contentWidth
            && lhs.contentWidthValueType == rhs.contentWidthValueType
    }

    /// NSTextStorage ranges use UTF-16; never cut through a composed character
    /// or accept visually equal text with different UTF-16 bytes. Comparing the
    /// attributed prefix also covers fonts, paragraph layout and role blocks.
    private static func unchangedAttributedPrefixLength(
        _ old: NSAttributedString, _ next: NSAttributedString, maxLength: Int = .max
    ) -> Int {
        let oldText = old.string as NSString
        let nextText = next.string as NSString
        let limit = min(oldText.length, nextText.length, maxLength)
        var textLength = 0
        // 分块取 UTF-16 单元后 memcmp，替代逐字符 objc 调用；结果与逐字符比较相同。
        let chunk = 512
        var oldBuffer = [unichar](repeating: 0, count: chunk)
        var nextBuffer = [unichar](repeating: 0, count: chunk)
        while textLength < limit {
            let count = min(chunk, limit - textLength)
            oldText.getCharacters(&oldBuffer, range: NSRange(location: textLength, length: count))
            nextText.getCharacters(&nextBuffer, range: NSRange(location: textLength, length: count))
            if memcmp(oldBuffer, nextBuffer, count * MemoryLayout<unichar>.size) == 0 {
                textLength += count
                continue
            }
            var index = 0
            while index < count, oldBuffer[index] == nextBuffer[index] { index += 1 }
            textLength += index
            break
        }
        var length = 0
        while length < textLength {
            var oldRun = NSRange()
            var nextRun = NSRange()
            let oldAttributes = old.attributes(at: length, effectiveRange: &oldRun)
            let nextAttributes = next.attributes(at: length, effectiveRange: &nextRun)
            guard Self.attributesEquivalent(oldAttributes, nextAttributes) else { break }
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
            .displaySuffix ?? ""
        // 显示层缩短：核心库固定前缀整句换成一个分隔符，只留统计；完整说明放在“展开工具输出”的悬停提示里。
        let collapsedNotice = "仅显示统计，结果正文未在此展示（该工具已真实执行并返回结果；正文按上下文策略未保留，需要时重新调用读取）"
        var metrics = summary
        if metrics.hasPrefix(collapsedNotice) {
            metrics = String(metrics.dropFirst(collapsedNotice.count))
            if metrics.hasPrefix("；") { metrics = String(metrics.dropFirst()) }
        }
        display.content = metrics.isEmpty ? "工具输出已折叠" : "工具输出已折叠 · " + metrics
        return display
    }

    /// 思考块标题：流式中「正在思考…」；有耗时显示「思考了 N 秒」；否则显示字数。
    static func thinkingTitle(thinking: String, seconds: Double?, isThinkingNow: Bool) -> String {
        if isThinkingNow { return "正在思考…" }
        if let seconds, seconds >= 1 { return "思考了 \(Int(seconds.rounded())) 秒" }
        return "思考过程 · \(thinking.count) 字"
    }

    /// 视图投影：展开状态属于显示层，只对展开的助手消息打标，原消息不变。
    static func thinkingDisplayMessage(_ message: ChatMessageUI, expanded: Bool) -> ChatMessageUI {
        guard expanded, message.role == .assistant,
              message.thinkingText?.isEmpty == false else { return message }
        var display = message
        display.thinkingExpanded = true
        return display
    }

    /// 助手消息上方的可折叠「思考过程」：默认只显示一行标题，展开后显示灰色小字全文。
    private static func thinkingSection(
        _ message: ChatMessageUI, baseSize: CGFloat, redactor: ChatTranscriptRedactor?,
        palette: Aj38Palette?, block: NSTextBlock
    ) -> NSAttributedString? {
        guard message.role == .assistant, let thinking = message.thinkingText, !thinking.isEmpty else { return nil }
        let expanded = message.thinkingExpanded && !message.isStreaming
        let title = thinkingTitle(thinking: thinking, seconds: message.thinkingSeconds,
                                  isThinkingNow: message.isStreaming && message.content.isEmpty)
        let font = NSFont.systemFont(ofSize: max(9, baseSize - 2))
        let color = palette.map { nsColor($0.textSecondary) } ?? NSColor.secondaryLabelColor
        let section = NSMutableAttributedString(
            string: (expanded ? "▾ " : "▸ ") + title + "\n",
            attributes: [.font: font, .foregroundColor: color])
        if expanded {
            var text = thinking
            if let redactor {
                TranscriptOperationDiagnostics.redactorCall(mode: "visible")
                text = redactor.redactVisibleConversationBody(text)
            }
            section.append(NSAttributedString(
                string: text + "\n", attributes: [.font: font, .foregroundColor: color.withAlphaComponent(0.85)]))
        }
        applyReadingParagraphStyle(to: section, role: message.role, block: block)
        return section
    }

    static func formattedMessage(
        _ message: ChatMessageUI, baseSize: CGFloat,
        redactor: ChatTranscriptRedactor?, palette: Aj38Palette? = nil,
        block suppliedBlock: NSTextBlock? = nil,
        inlineTools: [ChatInlineToolGap] = [],
        blockCache: MarkdownBlockRenderCache? = nil
    ) -> NSAttributedString {
        formattedMessageWithBody(
            message, baseSize: baseSize, redactor: redactor, palette: palette,
            block: suppliedBlock, inlineTools: inlineTools, blockCache: blockCache
        ).attributed
    }

    /// 同时返回可见正文，供无障碍文本复用，避免对同一条消息脱敏两次。
    static func formattedMessageWithBody(
        _ message: ChatMessageUI, baseSize: CGFloat,
        redactor: ChatTranscriptRedactor?, palette: Aj38Palette? = nil,
        block suppliedBlock: NSTextBlock? = nil,
        inlineTools: [ChatInlineToolGap] = [],
        blockCache: MarkdownBlockRenderCache? = nil,
        streamRedaction: StreamingDisplayRedactionCache? = nil
    ) -> (attributed: NSAttributedString, body: String) {
        let perf = PerformanceSignposts.begin(.transcriptFormatMessage); defer { perf.end() }
        if message.isBackgroundCompletionNotice {
            return (backgroundCompletionNoticeLine(baseSize: baseSize, palette: palette), backgroundCompletionNoticeText)
        }
        let body = visibleBodyText(message, redactor: redactor, streamRedaction: streamRedaction)
        let block = suppliedBlock ?? (message.role == .user ? UserBubbleTextBlock() : NSTextBlock())
        block.backgroundColor = roleBackgroundColor(message.role, palette: palette)
        (block as? UserBubbleTextBlock)?.applyBubbleGeometry()
        let result = NSMutableAttributedString(attributedString: roleHeader(
            message.role, baseSize: baseSize, palette: palette, block: block
        ))
        // 模型思考过程：只在显示层出现，不进入 body / 复制 / 导出 / 历史。
        if let thinking = thinkingSection(message, baseSize: baseSize, redactor: redactor,
                                          palette: palette, block: block) {
            result.append(thinking)
        }
        let content: NSMutableAttributedString
        if !inlineTools.isEmpty, message.role == .assistant {
            content = inlineBody(message: message, body: body, gaps: inlineTools,
                baseSize: baseSize, color: palette.map { nsColor($0.textPrimary) } ?? .textColor,
                redactor: redactor, blockCache: blockCache)
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
                baseColor: palette.map { nsColor($0.textPrimary) } ?? .textColor,
                isStreaming: message.isStreaming, blockCache: blockCache
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
        return (result, body)
    }

    /// Split only the already-redacted body, after proving that the producer
    /// boundary survives the whole-body redaction unchanged. A secret crossing
    /// a boundary must not be exposed by independently rendering raw fragments.
    private static func inlineBody(
        message: ChatMessageUI, body: String, gaps: [ChatInlineToolGap],
        baseSize: CGFloat, color: NSColor, redactor: ChatTranscriptRedactor?,
        blockCache: MarkdownBlockRenderCache? = nil
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
                        baseSize: baseSize, baseColor: color, isStreaming: message.isStreaming,
                        blockCache: blockCache))
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
                baseSize: baseSize, baseColor: color, isStreaming: message.isStreaming,
                blockCache: blockCache))
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
            accessibilityText(for: message, body: visibleBodyText(message, redactor: redactor))
        }.joined(separator: "\n\n")
    }

    /// 后台任务完成通知的显示文字：只在显示层替换，发给模型的内容（消息正文）不变。
    static let backgroundCompletionNoticeText = "后台任务已完成，已自动继续"

    /// 灰色系统提示一行：居中、次要色、小字，前面带成功状态图标（渲染时由状态图标投影换成 MinisIcon）。
    private static func backgroundCompletionNoticeLine(baseSize: CGFloat, palette: Aj38Palette?) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.firstLineHeadIndent = ChatReadingLayout.horizontalInset
        style.headIndent = ChatReadingLayout.horizontalInset
        style.tailIndent = -ChatReadingLayout.horizontalInset
        style.paragraphSpacingBefore = ChatReadingLayout.paragraphSpacingBefore
        return NSAttributedString(string: "✅ " + backgroundCompletionNoticeText, attributes: [
            .font: NSFont.systemFont(ofSize: max(11, baseSize * 0.85)),
            .foregroundColor: palette.map { nsColor($0.textSecondary) } ?? NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
    }

    /// 单条消息的无障碍文本；`body` 必须是同一消息的 `visibleBodyText`。
    static func accessibilityText(for message: ChatMessageUI, body: String) -> String {
        if message.isBackgroundCompletionNotice { return "系统提示：" + backgroundCompletionNoticeText }
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

    private static func visibleBodyText(
        _ message: ChatMessageUI, redactor: ChatTranscriptRedactor?,
        streamRedaction: StreamingDisplayRedactionCache? = nil
    ) -> String {
        guard message.role == .tool else {
            return bodyText(message, redactor: redactor, streamRedaction: streamRedaction)
        }
        // Redact raw text before projection so inserting a marker cannot split
        // a known-value redaction match. Hidden outputs retain their boundary.
        if message.content.count > ProductRedactionPolicy.maxTranscriptFieldLength {
            let markers = InvisibleCharacterPolicy.markerInventory(message.content)
            return bodyText(message, redactor: redactor)
                + (markers.isEmpty ? "" : "\n不可见字符：" + markers)
        }
        return InvisibleCharacterPolicy.visible(bodyText(message, redactor: redactor))
    }

    private static func bodyText(
        _ message: ChatMessageUI, redactor: ChatTranscriptRedactor? = nil,
        streamRedaction: StreamingDisplayRedactionCache? = nil
    ) -> String {
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
            // 流式中的助手消息：只扫新增尾部，结果与全量逐字节一致（见 StreamingDisplayRedactionCache）。
            if message.role == .assistant, message.isStreaming, let streamRedaction {
                return streamRedaction.redactedBody(
                    messageID: message.id, body: body, secrets: redactor.secretValues)
            }
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
                // 代码卡片的上下留白由构建器写在首段段前、末段段后（见 appendCode），这里保留；
                // 普通代码行之间不加段距与行距。
                let isCodeSurface = style.textBlocks.last is CodeSurfaceTextBlock
                if !isCodeSurface {
                    style.paragraphSpacingBefore = 0
                    style.paragraphSpacing = 0
                }
                style.lineSpacing = 0
            }
            let existingFirstLineInset = max(0, style.firstLineHeadIndent)
            let existingBlockInset = max(0, style.headIndent)
            let existingTrailingInset = min(0, style.tailIndent)

            // 用户消息靠右成块：左侧再缩进 wrapInset，让长消息不占满整栏（文本块外边距在这套排版里不生效，用段落缩进）。
            let userBubbleInset: CGFloat = role == .user ? UserBubbleTextBlock.wrapInset : 0
            style.firstLineHeadIndent = ChatReadingLayout.horizontalInset + userBubbleInset + existingFirstLineInset
            style.headIndent = ChatReadingLayout.horizontalInset + userBubbleInset + existingBlockInset
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

// MARK: - 对话中的本地图片缩略图

/// 回复正文里提到的本地图片：Markdown 图片语法 `![](路径)` 和独立成行的图片路径。
/// 只认本地文件（绝不加载 http(s) 等远程地址，防外泄）；文件必须存在、扩展名是图片、
/// 不超过大小上限、不是敏感文件，并且落在当前项目目录内。纯函数，可单测。
enum TranscriptInlineImages {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumPerMessage = 4
    static let maximumTotal = 8

    private static let markdownImage = try? NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(\s*<?([^)\n>]+?)>?\s*\)"#)

    static func imageURLs(
        in text: String,
        projectRoot: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        limit: Int = maximumPerMessage
    ) -> [URL] {
        guard let projectRoot else { return [] }
        var candidates: [String] = []
        let ns = text as NSString
        if let markdownImage {
            for match in markdownImage.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where match.numberOfRanges > 1 {
                candidates.append(ns.substring(with: match.range(at: 1)))
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var token = line.trimmingCharacters(in: .whitespaces)
            if token.count >= 2, let first = token.first, "`\"'".contains(first), token.last == first {
                token = String(token.dropFirst().dropLast())
            }
            // 独立成行：整行就是一个路径（含空格的路径只认引号包住的，已在上面去掉引号）。
            // 项目符号行（“- 路径”“* 路径”）去掉前缀后再判断。
            if token.hasPrefix("- ") || token.hasPrefix("* ") {
                token = token.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if token.count >= 2, let first = token.first, "`\"'".contains(first), token.last == first {
                    token = String(token.dropFirst().dropLast())
                }
            }
            guard !token.isEmpty, !token.hasPrefix("!"), !token.hasPrefix("-"), !token.hasPrefix("*") else { continue }
            candidates.append(token)
        }
        var seen = Set<String>()
        var result: [URL] = []
        for candidate in candidates {
            guard result.count < limit else { break }
            guard let url = validatedImageURL(candidate, projectRoot: projectRoot, home: home),
                  seen.insert(url.path).inserted else { continue }
            result.append(url)
        }
        return result
    }

    static func validatedImageURL(_ raw: String, projectRoot: URL, home: URL,
                                  fileManager: FileManager = .default) -> URL? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = token.lowercased()
        guard !token.isEmpty, token.count <= 1_024,
              !lower.hasPrefix("http:"), !lower.hasPrefix("https:"), !lower.hasPrefix("data:"),
              !lower.hasPrefix("file:"), !token.hasPrefix("//"),
              !lower.contains("://"),
              imageExtensions.contains((token as NSString).pathExtension.lowercased()) else { return nil }
        let path: String
        if token.hasPrefix("/") { path = token }
        else if token.hasPrefix("~/") { path = home.appendingPathComponent(String(token.dropFirst(2))).path }
        else { path = projectRoot.appendingPathComponent(token).path }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        // 项目目录内；另允许应用自己产生的图：浏览器截图（临时目录 browser_*.jpg）和 MCP 图片（会话输出目录 mcp-image-*）。
        // 桌面、/tmp 里的其它图片仍不放行。
        let name = resolved.lastPathComponent
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        let isBrowserShot = name.hasPrefix("browser_")
            && resolved.path.hasPrefix(tempRoot.hasSuffix("/") ? tempRoot : tempRoot + "/")
        let isMCPImage = name.hasPrefix("mcp-image-") && resolved.pathComponents.contains("tool-output")
        guard resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") || isBrowserShot || isMCPImage,
              !SensitiveFilePolicy.contains(resolved.path),
              !SensitiveFilePolicy.contains(path) else { return nil }
        var info = stat()
        guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              Int(info.st_size) <= maximumBytes else { return nil }
        return resolved
    }

    /// 缩略图解码：ImageIO 限幅（长边约 320pt，按 2x 取 640 像素），不把原图整张解码。
    static func thumbnail(at url: URL, maxPixel: Int = 640) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// 缩略图缓存（路径 + 修改时间为键）。
@MainActor
enum TranscriptInlineImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func key(_ url: URL) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)" as NSString
    }

    static func image(for key: NSString) -> NSImage? { cache.object(forKey: key) }

    static func store(_ image: NSImage, for key: NSString) {
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
    }
}

private struct TranscriptThumbnailBox: @unchecked Sendable { let image: CGImage? }

/// 对话末尾的图片缩略图条：显示最近回复里提到的本地图片，点击在右侧预览打开。
/// 流式输出中不计算，回复完成后才出现。
struct TranscriptInlineImageStrip: View {
    let messages: [ChatMessageUI]
    let projectRoot: URL?
    @Environment(\.transcriptImagePreviewAction) private var onPreview
    @State private var urls: [URL] = []

    private struct TaskKey: Equatable {
        let count: Int
        let lastLength: Int
        let streaming: Bool
        let root: String?
    }

    private var taskKey: TaskKey {
        TaskKey(count: messages.count, lastLength: messages.last?.content.utf8.count ?? 0,
                streaming: messages.contains(where: \.isStreaming), root: projectRoot?.path)
    }

    var body: some View {
        Group {
            if !urls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("对话中的图片")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(urls, id: \.path) { url in
                                TranscriptInlineImageThumbnail(url: url) { _ = onPreview?(url) }
                            }
                        }
                    }
                }
                .padding(.horizontal, ChatReadingLayout.horizontalInset)
            }
        }
        .task(id: taskKey) {
            guard let projectRoot, !messages.contains(where: \.isStreaming) else { urls = []; return }
            let bodies = messages.filter { $0.role == .assistant }.suffix(20).map(\.content)
            urls = await Task.detached(priority: .utility) {
                var all: [URL] = []
                for body in bodies {
                    for url in TranscriptInlineImages.imageURLs(in: body, projectRoot: projectRoot)
                    where !all.contains(url) { all.append(url) }
                }
                return Array(all.suffix(TranscriptInlineImages.maximumTotal))
            }.value
        }
    }
}

private struct TranscriptInlineImageThumbnail: View {
    let url: URL
    let onOpen: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: onOpen) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320, maxHeight: 320)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 96, height: 96)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("点击在右侧预览：\(url.lastPathComponent)")
        .accessibilityLabel("图片 \(url.lastPathComponent)")
        .task(id: url.path) {
            let key = TranscriptInlineImageCache.key(url)
            if let hit = TranscriptInlineImageCache.image(for: key) { image = hit; return }
            let box = await Task.detached(priority: .utility) {
                TranscriptThumbnailBox(image: TranscriptInlineImages.thumbnail(at: url))
            }.value
            guard let cg = box.image else { return }
            let decoded = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            TranscriptInlineImageCache.store(decoded, for: key)
            image = decoded
        }
    }
}

extension ChatMessageUI {
    /// 后台任务完成后 App 自动发出的那条【系统通知】：仍以用户角色发给模型，但显示成灰色系统提示。
    /// 与自动续跑计数使用同一个前缀判断，不新增持久化字段。
    var isBackgroundCompletionNotice: Bool {
        role == .user && content.hasPrefix(ChatStore.backgroundCompletionContinuationPrompt)
    }
}
