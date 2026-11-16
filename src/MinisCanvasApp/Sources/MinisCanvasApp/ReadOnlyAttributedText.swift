import SwiftUI
import AppKit
import MinisCore

// MARK: - 只读渲染状态（P3-UI-08 / P3-SAFE-11）

/// 富文本 consumer 的结果状态。状态不携带原始链接、路径或工具元数据，
/// 因而可以安全地用于可见提示和无障碍说明。
enum ReadOnlyAttributedTextStatus: Equatable {
    case rendered
    case sanitized
    case fallback

    var userMessage: String? {
        switch self {
        case .rendered:
            return nil
        case .sanitized:
            return "部分格式已按安全文本显示。"
        case .fallback:
            return "Markdown 格式异常，已按纯文本显示。"
        }
    }
}

/// assistant 文本从 source 到只读显示的不可变结果。
/// 这是生产 consumer 与直接测试共用的 contract；不执行链接、附件或其它副作用。
struct ReadOnlyAttributedTextRenderState: Equatable {
    let attributedString: NSAttributedString
    let status: ReadOnlyAttributedTextStatus

    var isFallback: Bool { status == .fallback }

    /// 稳定、无敏感详情的用户可见状态。原始 source 不从这里泄露。
    var statusMessage: String? { status.userMessage }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.attributedString.isEqual(to: rhs.attributedString)
    }
}

/// Only explicit HTTP(S) links receive navigation semantics. Other attributed
/// links and attachments continue to cross the existing display-only boundary.
enum TranscriptExternalLink {
    static let destination = NSAttributedString.Key("MinisCanvas.externalLink")
    // Session-scoped memory survives native text-view/Coordinator recreation.
    // It is deliberately never written to preferences or the conversation.
    @MainActor private static var confirmedHostsBySession: [UUID: Set<String>] = [:]

    @MainActor static func isConfirmed(host: String, sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return confirmedHostsBySession[sessionID]?.contains(host.lowercased()) == true
    }

    @MainActor static func confirm(host: String, sessionID: UUID?) {
        guard let sessionID else { return }
        confirmedHostsBySession[sessionID, default: []].insert(host.lowercased())
    }

    static func confirmationDisplay(for url: URL) -> String {
        let value = url.absoluteString
        return value.count > 512 ? String(value.prefix(512)) + "…" : value
    }

    static func allowedURL(_ value: Any?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

// MARK: - 消息正文的语义起始对齐（UF04）

/// 消息气泡的 role 容器由上层负责（用户靠右、assistant/tool 靠左）。
/// 这里仅约束容器内部的段落、列表和代码 glyph 使用同一 leading 起点，
/// 避免 NSTextView 沿用输入文本中不明确的 paragraph style 而发生漂移。
enum MessageContentAlignment {
    static let leading: NSTextAlignment = .left

    static func leadingParagraphStyle(from existing: NSParagraphStyle? = nil) -> NSParagraphStyle {
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.alignment = leading
        return style.copy() as! NSParagraphStyle
    }

    /// 为每个 attributed run 补齐 leading paragraph style，同时保留已有缩进、间距和行距。
    /// 该转换只改变正文的段落对齐，不改变字体、颜色、代码背景或文本结构。
    static func normalizedLeading(_ source: NSAttributedString) -> NSAttributedString {
        guard source.length > 0 else { return source }
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let existing = attributes[.paragraphStyle] as? NSParagraphStyle
            result.addAttribute(
                .paragraphStyle,
                value: leadingParagraphStyle(from: existing),
                range: range
            )
        }
        return result
    }
}

// MARK: - 只读富文本视图（AJ-26：文档内容原生 ⌘A 全选 / 跨段拖选）
//
// SwiftUI 的 Text(...).textSelection(.enabled) 只支持逐段选择，跨段（⌘A / 拖过多个块）
// 无效。这里用 NSTextView（isEditable=false, isSelectable=true）替代，原生支持整篇全选、
// 跨段拖选，同时保留 Markdown 富样式（标题/粗体/代码/列表/引用/表格/分隔线）。

/// 只读 NSTextView 包装：isEditable=false, isSelectable=true。
/// 原生 ⌘A 全选整篇 + 跨段拖选；不适合可编辑内容。
/// Bounded, opt-in diagnostics for the formal synthetic native transcript host.
/// This observes only the mounted text view's clip ancestors; no text, selection,
/// session contents or configuration is logged, and scrolling is never changed.
@MainActor
enum ChatTranscriptScrollDiagnostics {
    #if DEBUG
    // The flag enables observation only, never a runner or application action.
    static let enabled = ProcessInfo.processInfo.environment["MINISCANVAS_TRANSCRIPT_SCROLL_DIAGNOSTICS"] == "1"
        && RuntimeIsolationProfile.formalTestProfileForDefaultConsumer()?.mode == .isolatedTest
    #else
    static let enabled = false
    #endif
    private static var sequence = 0

    static func record(_ phase: String, _ fields: @autoclosure () -> String) {
        guard enabled, sequence < 256 else { return }
        sequence += 1
        print("TRANSCRIPT_SCROLL_TRACE sequence=\(sequence) time=\(ProcessInfo.processInfo.systemUptime) phase=\(phase) \(fields())")
    }

    static func state(_ state: ChatTranscriptScrollState) -> String {
        "following=\(state.isFollowing) nearBottom=\(state.isNearBottom) pending=\(state.pendingNewMessageCount)"
    }
}

@MainActor
final class ChatTranscriptNativeClipDiagnostics: NSObject {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        // Selector observers are zeroing-weak and automatically unregistered.
        // Do not enable postsBoundsChangedNotifications: report the native fact.
        #if DEBUG
        guard ChatTranscriptScrollDiagnostics.enabled else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: nil)
        snapshot("native-probe-installed")
        #endif
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSClipView else { return }
        snapshot("native-bounds", changed: changed)
    }

    func snapshot(_ phase: String, changed: NSClipView? = nil) {
        guard ChatTranscriptScrollDiagnostics.enabled, let textView else { return }
        var ancestor: NSView? = textView.superview
        var clips: [NSClipView] = []
        while let view = ancestor {
            if let clip = view as? NSClipView { clips.append(clip) }
            ancestor = view.superview
        }
        guard changed == nil || clips.contains(where: { $0 === changed }) else { return }
        let chain = clips.enumerated().map { index, clip in
            let scroll = clip.superview as? NSScrollView
            return "depth=\(index),clip=\(ObjectIdentifier(clip)),bounds=\(clip.bounds),posts=\(clip.postsBoundsChangedNotifications),scroll=\(String(describing: scroll.map(ObjectIdentifier.init))),scrollType=\(String(describing: scroll.map { type(of: $0) })),document=\(String(describing: scroll?.documentView?.bounds))"
        }.joined(separator: ";")
        ChatTranscriptScrollDiagnostics.record(phase,
            "text=\(ObjectIdentifier(textView)) window=\(String(describing: textView.window?.windowNumber)) visible=\(textView.visibleRect) changed=\(String(describing: changed.map(ObjectIdentifier.init))) chain=[\(chain)]")
    }
}

/// The transcript is content-sized inside SwiftUI's native outer scroll view.
/// Observe that actual clip, excluding this representable's inner scroll view.
/// The existing preference path missed native scroll events in this host.
@MainActor
final class ChatTranscriptNativeViewport: NSObject {
    private weak var innerScrollView: NSScrollView?
    var onChange: (@MainActor (Bool, Double) -> Void)?
    private var pendingRestorationOffset: Double?
    private var didRestore = false
    private var restoreScheduled = false

    init(innerScrollView: NSScrollView, onChange: @escaping @MainActor (Bool, Double) -> Void) {
        self.innerScrollView = innerScrollView
        self.onChange = onChange
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: nil)
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSClipView,
              let outer = outerScrollView(),
              changed === outer.contentView,
              outer.documentView != nil,
              changed.bounds.height > 0 else { return }
        if pendingRestorationOffset != nil {
            scheduleRestoration()
            return
        }
        guard onChange != nil else { return }
        // A native layout pass must not synchronously mutate SwiftUI state.
        // Re-read the live clip when the deferred callback runs. A wheel event
        // can move the same session from bottom to history before this task is
        // delivered; publishing the old near-bottom sample would re-enable
        // following and make the next stream delta pull the reader to the tail.
        Task { @MainActor [weak self, weak changed] in
            guard let self, let changed,
                  let outer = self.outerScrollView(),
                  changed === outer.contentView,
                  let document = outer.documentView,
                  changed.bounds.height > 0,
                  self.pendingRestorationOffset == nil,
                  let onChange = self.onChange else { return }
            let nearBottom = document.bounds.maxY - changed.bounds.maxY <= 24
            let verticalOffset = max(0, Double(changed.bounds.minY - document.bounds.minY))
            ChatTranscriptScrollDiagnostics.record("native-viewport",
                "clip=\(ObjectIdentifier(changed)) bounds=\(changed.bounds) document=\(document.bounds) near=\(nearBottom)")
            onChange(nearBottom, verticalOffset)
        }
    }

    func requestRestoration(_ verticalOffset: Double?) {
        guard !didRestore, let verticalOffset, verticalOffset.isFinite else { return }
        pendingRestorationOffset = max(0, verticalOffset)
        scheduleRestoration()
    }

    func cancelRestoration() {
        pendingRestorationOffset = nil
        onChange = nil
    }

    private func scheduleRestoration() {
        guard !restoreScheduled else { return }
        restoreScheduled = true
        // The new transcript's native host is attached before its outer SwiftUI
        // document has its final height. Restore only after that layout turn.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<8 {
                if attempt == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard self.pendingRestorationOffset != nil else { break }
                if self.restoreIfReady() { break }
            }
            self.restoreScheduled = false
        }
    }

    private func restoreIfReady() -> Bool {
        guard let verticalOffset = pendingRestorationOffset,
              onChange != nil,
              let outer = outerScrollView(),
              let document = outer.documentView else { return false }
        outer.layoutSubtreeIfNeeded()
        document.layoutSubtreeIfNeeded()
        let clip = outer.contentView
        let maxOffset = max(0, document.bounds.height - clip.bounds.height)
        guard clip.bounds.height > 0, maxOffset > 0 else { return false }
        pendingRestorationOffset = nil
        didRestore = true
        clip.scroll(to: NSPoint(
            x: clip.bounds.minX,
            y: document.bounds.minY + min(CGFloat(verticalOffset), maxOffset)
        ))
        outer.reflectScrolledClipView(clip)
        return true
    }

    private func outerScrollView() -> NSScrollView? {
        guard let innerScrollView else { return nil }
        return Self.outerScrollView(above: innerScrollView)
    }

    /// Both saving and restoration use the first scroll host *above* the
    /// content-sized NSTextView wrapper. The wrapper's own clip is not the
    /// user-operated transcript scrollbar.
    static func outerScrollView(above innerScrollView: NSScrollView) -> NSScrollView? {
        var ancestor = innerScrollView.superview
        while let view = ancestor {
            if let outer = view as? NSScrollView { return outer }
            ancestor = view.superview
        }
        return nil
    }
}

struct ReadOnlyAttributedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    /// Present only for the single chat transcript. The formatter has already
    /// redacted and sanitized both the document and the replacement suffix.
    let transcriptUpdate: ChatTranscriptStorageUpdate?
    private let transcriptTailStart: Int?
    private let linkSessionID: UUID?
    /// true = 作为消息气泡按内容高度布局；false = 作为全文转录交给外层滚动容器收缩。
    let fitContentHeight: Bool
    private let onTranscriptViewportChange: (@MainActor (Bool, Double) -> Void)?
    private let restoreTranscriptViewportOffset: Double?

    static let transcriptLineBreakMode: NSLineBreakMode = .byCharWrapping

    static func measuredContentHeight(usedRect: NSRect, inset: NSSize) -> CGFloat {
        max(1, ceil(usedRect.height + inset.height * 2) + 1)
    }

    init(attributedString: NSAttributedString, fitContentHeight: Bool = true) {
        // NSTextView 的 selectable 文本仍会执行带 .link 的 attributed string
        // 行为；先做一次 allow-list 清洗，保证 consumer 没有可执行链接或附件。
        self.attributedString = Self.sanitized(attributedString)
        self.transcriptUpdate = nil
        self.transcriptTailStart = nil
        self.linkSessionID = nil
        self.fitContentHeight = fitContentHeight
        self.onTranscriptViewportChange = nil
        self.restoreTranscriptViewportOffset = nil
    }

    init(transcriptDocument: ChatTranscriptFormattedDocument,
         update: ChatTranscriptStorageUpdate,
         sessionID: UUID? = nil,
         onViewportChange: (@MainActor (Bool, Double) -> Void)? = nil,
         restoreViewportOffset: Double? = nil) {
        self.attributedString = transcriptDocument.attributedString
        self.transcriptUpdate = update
        self.transcriptTailStart = transcriptDocument.messageStartLocations.last
        self.linkSessionID = sessionID
        self.fitContentHeight = true
        self.onTranscriptViewportChange = onViewportChange
        self.restoreTranscriptViewportOffset = restoreViewportOffset
    }

    /// 只保留排版属性，并把附件替换为明确的纯文本占位。
    /// 这样即便上游误传带 attachment/link 的 NSAttributedString，也不会触发
    /// NSWorkspace、文件路径或网络 URL 行为。
    nonisolated static func sanitized(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let allowed: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .backgroundColor, .paragraphStyle,
            .kern, .underlineStyle, .strikethroughStyle, .baselineOffset
        ]
        let fullRange = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var safeAttributes = attributes.filter { allowed.contains($0.key) }
            if let marker = attributes[ChatInlineToolGap.marker] as? String,
               ChatInlineToolGap.isMarkerID(marker) {
                safeAttributes[ChatInlineToolGap.marker] = marker
            }
            if let url = TranscriptExternalLink.allowedURL(attributes[TranscriptExternalLink.destination]) {
                safeAttributes[TranscriptExternalLink.destination] = url
                safeAttributes[.link] = url
            }
            let hasAttachment = attributes[.attachment] != nil
            let text: String
            if hasAttachment {
                text = "[附件内容已隐藏]"
            } else {
                let candidate = (source.string as NSString).substring(with: range)
                // U+FFFC is AppKit's object-replacement marker and can arrive
                // without a well-formed .attachment attribute after persistence.
                text = candidate.contains("\u{FFFC}") ? "[附件内容已隐藏]" : candidate
            }
            result.append(NSAttributedString(string: text, attributes: safeAttributes))
        }
        return NSAttributedString(attributedString: result)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        makeNSView(coordinator: context.coordinator)
    }

    /// The native consumer path also accepts its owned coordinator directly,
    /// so its storage and layout can be checked without a window or SwiftUI.
    func makeNSView(coordinator: Coordinator) -> NSScrollView {
        coordinator.linkSessionID = linkSessionID
        let scrollView = ChatTranscriptNativeTextView.makeScrollable()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        // Content-height hosts are measured by SwiftUI's proposal. AppKit
        // placement may temporarily have a different frame width; letting it
        // reflow the container would invalidate the height we just reported.
        textView.textContainer?.widthTracksTextView = !fitContentHeight
        textView.textContainer?.lineBreakMode = Self.transcriptLineBreakMode
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.delegate = coordinator
        // The transcript already supplies resolved foreground/background colors
        // from the selected theme. AppKit's adaptive mapping would invert those
        // component colors a second time in dark appearance, making light text
        // dark on the dark message surface. Other read-only documents still use
        // their existing adaptive mapping for system/default colors.
        textView.usesAdaptiveColorMappingForDarkAppearance = transcriptUpdate == nil
        if transcriptUpdate != nil {
            // The first native load is also part of the transcript path. Without
            // this interval, Instruments misses the 50k/100k initial apply.
            let signpost = TranscriptPerformanceSignposts.signposter.beginInterval(
                TranscriptPerformanceSignposts.nativeApply
            )
            if let storage = textView.textStorage {
                TranscriptOperationDiagnostics.textStorageEdit(
                    scope: transcriptUpdate?.diagnosticScope, host: "native", mode: "initialSet",
                    start: 0, removed: storage.length, inserted: attributedString.length,
                    oldLength: storage.length
                )
                storage.setAttributedString(attributedString)
            }
            TranscriptPerformanceSignposts.signposter.endInterval(
                TranscriptPerformanceSignposts.nativeApply, signpost
            )
        } else {
            textView.textStorage?.setAttributedString(attributedString)
        }
        coordinator.appliedTranscriptRevision = transcriptUpdate?.revision
        coordinator.appliedTranscriptGeneration = transcriptUpdate?.generation
        coordinator.appliedTranscriptTailStart = transcriptTailStart
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = !fitContentHeight
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        if let onTranscriptViewportChange {
            coordinator.transcriptViewport = ChatTranscriptNativeViewport(
                innerScrollView: scrollView, onChange: onTranscriptViewportChange
            )
            coordinator.transcriptViewport?.requestRestoration(restoreTranscriptViewportOffset)
        }
        if transcriptUpdate != nil, ChatTranscriptScrollDiagnostics.enabled {
            coordinator.scrollDiagnostics = ChatTranscriptNativeClipDiagnostics(textView: textView)
        }
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.transcriptViewport?.cancelRestoration()
        coordinator.transcriptViewport = nil
        coordinator.scrollDiagnostics = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        updateNSView(scrollView, coordinator: context.coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.linkSessionID = linkSessionID
        let textView = scrollView.documentView as! NSTextView
        coordinator.transcriptViewport?.onChange = onTranscriptViewportChange
        coordinator.transcriptViewport?.requestRestoration(restoreTranscriptViewportOffset)
        if let transcriptUpdate {
            coordinator.scrollDiagnostics?.snapshot("native-storage-update")
            ChatTranscriptScrollDiagnostics.record("storage-revision",
                "revision=\(transcriptUpdate.revision) applied=\(String(describing: coordinator.appliedTranscriptRevision))")
            let coord = coordinator
            guard coord.appliedTranscriptRevision != transcriptUpdate.revision else { return }
            let signpost = TranscriptPerformanceSignposts.signposter.beginInterval(
                TranscriptPerformanceSignposts.nativeApply
            )
            defer {
                TranscriptPerformanceSignposts.signposter.endInterval(
                    TranscriptPerformanceSignposts.nativeApply, signpost
                )
            }
            let storage = textView.textStorage
            // SwiftUI may coalesce multiple tail updates before calling us.
            // Appends require their exact base; repeated tail patches require
            // the same retained prefix. A missed append or
            // shortened tail can otherwise preserve stale text even when the
            // structural generation and character bounds still match.
            let canPatch = Self.canApplyTranscriptPatch(
                transcriptUpdate, appliedRevision: coord.appliedTranscriptRevision,
                appliedGeneration: coord.appliedTranscriptGeneration,
                appliedTailStart: coord.appliedTranscriptTailStart
            )
            // Use the attributed suffix only against its exact predecessor.
            // A coalesced tail update keeps the anchored recovery replacement;
            // a missed append or structural generation still takes the full set.
            if canPatch,
               let patch = transcriptUpdate.patch(
                   forAppliedRevision: coord.appliedTranscriptRevision
               ),
               let storage, patch.start >= 0, patch.start <= storage.length {
                let selected = Self.preservedSelectionRanges(
                    textView.selectedRanges,
                    contentLength: patch.start + patch.value.length
                )
                TranscriptOperationDiagnostics.textStorageEdit(
                    scope: transcriptUpdate.diagnosticScope, host: "native", mode: "tailReplace",
                    start: patch.start, removed: storage.length - patch.start,
                    inserted: patch.value.length, oldLength: storage.length
                )
                storage.replaceCharacters(
                    in: NSRange(location: patch.start, length: storage.length - patch.start),
                    with: patch.value
                )
                textView.selectedRanges = selected
                coord.pendingTailStart = patch.start
                coord.cachedHeight = 0
            } else {
                let selected = Self.preservedSelectionRanges(
                    textView.selectedRanges, contentLength: attributedString.length
                )
                if let storage {
                    TranscriptOperationDiagnostics.textStorageEdit(
                        scope: transcriptUpdate.diagnosticScope, host: "native", mode: "fullSet",
                        start: 0, removed: storage.length, inserted: attributedString.length,
                        oldLength: storage.length
                    )
                    storage.setAttributedString(attributedString)
                }
                textView.selectedRanges = selected
                coord.pendingTailStart = nil
                coord.cachedWidth = -1
                coord.cachedHeight = 0
            }
            coord.appliedTranscriptRevision = transcriptUpdate.revision
            coord.appliedTranscriptGeneration = transcriptUpdate.generation
            coord.appliedTranscriptTailStart = transcriptTailStart
            return
        }
        // SwiftUI 会因 hover、滚动或父级状态变化反复调用 update。无变化时不能重写
        // textStorage，否则 AppKit 会清除当前选区，表现为鼠标拖选/⌘A 后立刻失效。
        if Self.shouldReplaceTextStorage(
            current: textView.attributedString(),
            replacement: attributedString
        ) {
            let selectedRanges = Self.preservedSelectionRanges(
                textView.selectedRanges,
                contentLength: attributedString.length
            )
            textView.textStorage?.setAttributedString(attributedString)
            textView.selectedRanges = selectedRanges
            // 内容变化 → 失效测量缓存，下次 sizeThatFits 重新布局。
            coordinator.cachedWidth = -1
            coordinator.cachedHeight = 0
        }
    }

    static func canApplyTranscriptPatch(
        _ update: ChatTranscriptStorageUpdate,
        appliedRevision: UInt64?, appliedGeneration: UInt64?,
        appliedTailStart: Int?
    ) -> Bool {
        guard appliedGeneration == update.generation else { return false }
        // Repeated updates to the same tail preserve the prefix even when
        // SwiftUI skipped revisions. Appends require their exact base because
        // the preceding tail may have changed while the consumer was behind.
        return (update.baseRevision != nil && appliedRevision == update.baseRevision)
            || (appliedTailStart != nil && update.replacementStart == appliedTailStart)
    }

    /// 只有内容或属性真正变化时才写入 NSTextStorage。
    static func shouldReplaceTextStorage(
        current: NSAttributedString,
        replacement: NSAttributedString
    ) -> Bool {
        !current.isEqual(to: replacement)
    }

    /// 内容更新后保留所有选区，并将旧范围安全钳制到新内容长度。
    static func preservedSelectionRanges(
        _ ranges: [NSValue],
        contentLength: Int
    ) -> [NSValue] {
        let length = max(0, contentLength)
        return ranges.map { value in
            let range = value.rangeValue
            let start = min(max(0, range.location), length)
            let rawEnd: Int
            if range.location >= length {
                rawEnd = length
            } else {
                rawEnd = max(range.location, range.location + max(0, range.length))
            }
            let end = min(length, max(start, rawEnd))
            return NSValue(range: NSRange(location: start, length: end - start))
        }
    }

    /// AJ-71/72：按 SwiftUI 提案宽度布局文本并报告内容高度。
    /// NSScrollView 无 intrinsic size（fittingSize 恒为 0），聊天气泡（LazyVStack 内）必须
    /// 显式给高度，否则行高塌陷。宽度取 proposal.width——放置阶段即父容器分配的实际宽度，
    /// 保证「算高度的宽度」=「最终渲染宽度」（宽度/高度精确匹配，无截断无空白）；
    /// 量宽阶段（nil）兜底 480。DocumentView 场景无行为变化（外层拉伸仍生效）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        sizeThatFits(proposal, nsView: nsView, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, coordinator: Coordinator) -> CGSize? {
        guard fitContentHeight else { return nil }
        guard let textView = nsView.documentView as? NSTextView,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return nil }
        let width: CGFloat
        if let pw = proposal.width, pw.isFinite, pw > 0 {
            width = pw
        } else {
            width = 480
        }
        // P0-启动崩溃（2026-08-06）：原实现每次测量（含 AppKit 布局 pass 内）都重设
        // containerSize + ensureLayout——写入 NSTextView 状态使 NSHostingView 约束持续
        // dirty → 布局无限循环（300 iterations）→ 计数超限崩溃。修复：同宽度（±0.5pt
        // 抖动容差）命中缓存直接返回，测量零副作用；仅宽度真实变化（窗口 resize）才重新
        // 布局。内容更新（updateNSView）会失效缓存，新内容高度照常刷新。
        let coord = coordinator
        if abs(coord.cachedWidth - width) < 0.5,
           coord.cachedHeight > 0, coord.pendingTailStart == nil {
            return CGSize(width: width, height: coord.cachedHeight)
        }
        let signpost = transcriptUpdate.map { _ in
            TranscriptPerformanceSignposts.signposter.beginInterval(
                TranscriptPerformanceSignposts.layout
            )
        }
        defer {
            if let signpost {
                TranscriptPerformanceSignposts.signposter.endInterval(
                    TranscriptPerformanceSignposts.layout, signpost
                )
            }
        }
        let sameWidth = abs(coord.cachedWidth - width) < 0.5
        if !sameWidth {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = false
        }
        let contentLength = textView.attributedString().length
        if sameWidth, let start = coord.pendingTailStart, start < contentLength {
            TranscriptOperationDiagnostics.layoutRequest(
                scope: transcriptUpdate?.diagnosticScope, host: "native", mode: "tail",
                start: start, length: contentLength - start,
                documentLength: contentLength
            )
            layoutManager.ensureLayout(forCharacterRange: NSRange(
                location: start, length: contentLength - start
            ))
        } else {
            TranscriptOperationDiagnostics.layoutRequest(
                scope: transcriptUpdate?.diagnosticScope,
                host: "native",
                mode: sameWidth ? "full" : "widthChange",
                start: 0, length: contentLength, documentLength: contentLength
            )
            layoutManager.ensureLayout(for: container)
        }
        // 始终使用当前 layout manager 的 document rect。textView.frame 可能保留
        // 上一个会话的高度，拿它做缓存会让新会话正文塌陷或保留旧空白。
        let height = Self.measuredContentHeight(
            usedRect: layoutManager.usedRect(for: container),
            inset: textView.textContainerInset
        )
        coord.cachedWidth = width
        coord.cachedHeight = height
        coord.pendingTailStart = nil
        return CGSize(width: width, height: coord.cachedHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var linkSessionID: UUID?
        private var confirmingLink = false

        @MainActor func hasConfirmedLink(to host: String) -> Bool {
            TranscriptExternalLink.isConfirmed(host: host, sessionID: linkSessionID)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard charIndex >= 0, charIndex < textView.attributedString().length,
                  let url = TranscriptExternalLink.allowedURL(
                    textView.attributedString().attribute(TranscriptExternalLink.destination, at: charIndex, effectiveRange: nil)
                  ), let host = url.host else { return true }
            if hasConfirmedLink(to: host) {
                NSWorkspace.shared.open(url)
                return true
            }
            guard !confirmingLink, let window = textView.window else { return true }
            confirmingLink = true
            let alert = NSAlert()
            alert.messageText = "打开外部链接？"
            alert.informativeText = "将使用默认浏览器打开：\n\(TranscriptExternalLink.confirmationDisplay(for: url))"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "打开链接")
            let confirmedSessionID = linkSessionID
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.confirmingLink = false
                guard response == .alertSecondButtonReturn else { return }
                TranscriptExternalLink.confirm(host: host, sessionID: confirmedSessionID)
                NSWorkspace.shared.open(url)
            }
            // Always consume AppKit's default navigation, including cancellation.
            return true
        }

        /// 测量缓存：同宽度命中直接返回（避免测量副作用触发布局循环）。
        /// cachedWidth = -1 表示未测量（首次 / updateNSView 失效后）。
        var transcriptViewport: ChatTranscriptNativeViewport?
        var scrollDiagnostics: ChatTranscriptNativeClipDiagnostics?
        var cachedWidth: CGFloat = -1
        var cachedHeight: CGFloat = 0
        var pendingTailStart: Int?
        var appliedTranscriptRevision: UInt64?
        var appliedTranscriptGeneration: UInt64?
        var appliedTranscriptTailStart: Int?
    }
}

// MARK: - Markdown → NSAttributedString 构建器（AJ-26 富样式保留）

/// 把文档内容（Markdown 或纯文本）构建为 NSAttributedString，供只读 NSTextView 渲染。
/// 纯函数，文档内容可完整测试。
enum MarkdownAttributedTextBuilder {

    /// 生产渲染入口：解析结果和状态一起返回，避免 malformed 输入被静默吞掉。
    static func renderState(
        content: String,
        isMarkdown: Bool,
        baseSize: CGFloat = 13,
        baseColor: NSColor = .textColor
    ) -> ReadOnlyAttributedTextRenderState {
        guard isMarkdown else {
            return ReadOnlyAttributedTextRenderState(
                attributedString: buildPlain(content: content, baseSize: baseSize, baseColor: baseColor),
                status: .rendered
            )
        }

        TranscriptOperationDiagnostics.parserCall(kind: "block")
        let blocks = MinisCore.MarkdownParser.parse(content)
        // Reuse only byte-identical inline safety results within this render.
        var inlineAssessments: [Data: ReadOnlyAttributedTextStatus] = [:]
        let assessment = assess(blocks, inlineAssessments: &inlineAssessments)
        let rendered = NSMutableAttributedString(attributedString:
            attributed(from: blocks, baseSize: baseSize, baseColor: baseColor,
                inlineAssessments: inlineAssessments))
        if assessment == .fallback {
            rendered.append(NSAttributedString(string: "\n" + (assessment.userMessage ?? ""), attributes: [
                .font: NSFont.systemFont(ofSize: max(10, baseSize - 1)),
                .foregroundColor: baseColor.withAlphaComponent(0.68)
            ]))
        }
        return ReadOnlyAttributedTextRenderState(
            attributedString: rendered,
            status: assessment
        )
    }

    /// 入口：isMarkdown=true 走块级 Markdown 渲染；false 走等宽纯文本。
    /// baseColor：正文基色（默认 .textColor；AJ-71 聊天用户白字气泡传 .white），
    /// 次级元素（列表标记/引用/代码语言/分隔线）由基色按透明度派生。
    static func build(content: String, isMarkdown: Bool, baseSize: CGFloat = 13, baseColor: NSColor = .textColor) -> NSAttributedString {
        renderState(content: content, isMarkdown: isMarkdown, baseSize: baseSize, baseColor: baseColor).attributedString
    }

    private static func buildPlain(content: String, baseSize: CGFloat, baseColor: NSColor) -> NSAttributedString {
        MessageContentAlignment.normalizedLeading(NSAttributedString(
            string: content,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
                .foregroundColor: baseColor,
            ]
        ))
    }

    private static func visibleTextWithoutLinkDestinations(_ content: String) -> String {
        // Keep the human-facing label while dropping destination/metadata. This is
        // deliberately a small, deterministic fallback transform, not a URL opener.
        // The closing parenthesis is optional so a truncated link cannot leak its
        // destination in the fallback surface.
        let pattern = #"!?\[([^\]]*)\]\([^\)]*(?:\)|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return expression.stringByReplacingMatches(in: content, range: range, withTemplate: "$1")
    }

    private static func assess(_ blocks: [MinisCore.MarkdownBlock]) -> ReadOnlyAttributedTextStatus {
        var inlineAssessments: [Data: ReadOnlyAttributedTextStatus] = [:]
        return assess(blocks, inlineAssessments: &inlineAssessments)
    }

    private static func assess(
        _ blocks: [MinisCore.MarkdownBlock],
        inlineAssessments: inout [Data: ReadOnlyAttributedTextStatus]
    ) -> ReadOnlyAttributedTextStatus {
        var sawLink = false
        var malformed = false
        for block in blocks {
            let inlineTexts: [String]
            switch block {
            case .heading(_, let text), .paragraph(let text), .blockquote(let text):
                inlineTexts = [text]
            case .list(let items, _):
                inlineTexts = items
            case .table(let header, let rows):
                inlineTexts = header + rows.flatMap { $0 }
            case .codeBlock(_, _), .divider:
                inlineTexts = []
            }

            for text in inlineTexts {
                let key = Data(text.utf8)
                let status: ReadOnlyAttributedTextStatus
                if let existing = inlineAssessments[key] {
                    status = existing
                } else {
                    status = assessInline(text)
                    inlineAssessments[key] = status
                }
                sawLink = sawLink || status == .sanitized
                malformed = malformed || status == .fallback
            }
        }
        if malformed { return .fallback }
        return sawLink ? .sanitized : .rendered
    }

    private static func assessInline(_ text: String) -> ReadOnlyAttributedTextStatus {
        var sawLink = false
        var malformed = false
        TranscriptOperationDiagnostics.parserCall(kind: "assessment-inline", observerOnly: true)
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            for run in parsed.runs {
                if let url = run.link, TranscriptExternalLink.allowedURL(url) == nil {
                    sawLink = true
                }
            }
        } else {
            malformed = true
        }
        // An odd inline delimiter is a common streaming/malformed state.
        // Treating it as plain text is deterministic and keeps the source visible.
        let backticks = text.filter { $0 == "`" }.count
        // A symbol-only value between a value separator and a value terminator
        // has no strong content. Do not split its run into many empty pairs.
        // Ambiguous Markdown openers keep the original unmatched-strong guard.
        var strongPairs = 0
        var originalStrongPairs = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "*" else { cursor = text.index(after: cursor); continue }
            let start = cursor
            var length = 0
            while cursor < text.endIndex, text[cursor] == "*" {
                length += 1
                cursor = text.index(after: cursor)
            }
            let before = start == text.startIndex ? nil : text[text.index(before: start)]
            let after = cursor == text.endIndex ? nil : text[cursor]
            let valuePrefix = before.map { "=:：".contains($0) } ?? false
            let valueEnd = after.map { $0.isWhitespace || ";；".contains($0) } ?? true
            let literalRun = length > 2 && valuePrefix && valueEnd && strongPairs % 2 == 0
            originalStrongPairs += length / 2
            if !literalRun { strongPairs += length / 2 }
        }
        // Discounting a literal run must never turn an originally balanced
        // paragraph into a new imbalance (including a run closing emphasis).
        let unbalancedStrong = originalStrongPairs % 2 != 0 && strongPairs % 2 != 0
        if backticks % 2 != 0 || unbalancedStrong || hasMalformedLinkSyntax(text) {
            malformed = true
        }
        if malformed { return .fallback }
        return sawLink ? .sanitized : .rendered
    }

    private static func hasMalformedLinkSyntax(_ text: String) -> Bool {
        guard text.contains("](") || text.contains("![") else { return false }
        let pattern = #"!?\[[^\]]*\]\([^\)]*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let validCount = expression.numberOfMatches(in: text, range: range)
        let markerCount = max(0, text.components(separatedBy: "](").count - 1)
        return validCount < markerCount
    }

    /// 块级 Markdown → 富文本。块间换行分隔。
    /// baseColor：正文基色，次级元素由基色按透明度派生（浅色/深色气泡背景上都可读）。
    static func attributed(from blocks: [MinisCore.MarkdownBlock], baseSize: CGFloat = 13, baseColor: NSColor = .textColor) -> NSAttributedString {
        attributed(from: blocks, baseSize: baseSize, baseColor: baseColor, inlineAssessments: [:])
    }

    private static func attributed(
        from blocks: [MinisCore.MarkdownBlock], baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                appendHeading(text, level: level, to: result, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments)
            case .paragraph(let t):
                result.append(inlineAttributed(t, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments))
                result.append(NSAttributedString(string: "\n"))
            case .codeBlock(let language, let code):
                appendCode(language: language, code: code, to: result, baseSize: baseSize, baseColor: baseColor)
            case .blockquote(let t):
                appendBlockquote(t, to: result, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments)
            case .list(let items, let ordered):
                appendList(items, ordered: ordered, to: result, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments)
            case .table(let header, let rows):
                appendTable(header, rows: rows, to: result, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments)
            case .divider:
                appendDivider(to: result, baseSize: baseSize, baseColor: baseColor)
            }
        }
        return MessageContentAlignment.normalizedLeading(result)
    }

    // MARK: 块渲染

    private static func appendHeading(_ text: String, level: Int, to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]) {
        let size = headingSize(level, baseSize: baseSize)
        let font = NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
        result.append(inlineAttributed(text, baseSize: size, baseColor: baseColor, forceFont: font, inlineAssessments: inlineAssessments))
        result.append(NSAttributedString(string: "\n\n"))
    }

    private static func appendCode(language: String?, code: String, to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor) {
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        if let language, !language.isEmpty {
            result.append(NSAttributedString(
                string: language + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: baseSize - 2, weight: .medium),
                    .foregroundColor: baseColor.withAlphaComponent(0.75)
                ]
            ))
        }
        let surface = NSTextBlock()
        surface.backgroundColor = baseColor.withAlphaComponent(0.12)
        surface.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
        surface.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [surface]
        result.append(NSAttributedString(
            string: code + "\n",
            attributes: [.font: codeFont, .foregroundColor: baseColor, .paragraphStyle: style]
        ))
    }

    private static func appendBlockquote(_ text: String, to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]) {
        let para = NSMutableParagraphStyle()
        para.headIndent = 12
        let m = NSMutableAttributedString(attributedString: inlineAttributed(text, baseSize: baseSize, baseColor: baseColor.withAlphaComponent(0.75), inlineAssessments: inlineAssessments))
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        result.append(m)
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendList(_ items: [String], ordered: Bool, to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]) {
        for (i, item) in items.enumerated() {
            let marker = ordered ? "\(i + 1). " : "• "
            result.append(NSAttributedString(
                string: marker,
                attributes: [.font: NSFont.systemFont(ofSize: baseSize, weight: .semibold), .foregroundColor: baseColor.withAlphaComponent(0.75)]
            ))
            result.append(inlineAttributed(item, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments))
            result.append(NSAttributedString(string: "\n"))
        }
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendTable(_ header: [String], rows: [[String]], to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]) {
        guard !header.isEmpty else { return }
        let table = NSTextTable()
        table.numberOfColumns = header.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setValue(100, type: .percentageValueType, for: .width)
        let visibleRows = [header] + Array(rows.prefix(200))
        for (rowIndex, row) in visibleRows.enumerated() {
            for column in header.indices {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                            startingColumn: column, columnSpan: 1)
                cell.setValue(100 / CGFloat(header.count), type: .percentageValueType, for: .width)
                cell.setWidth(ChatReadingLayout.tablePadding, type: .absoluteValueType, for: .padding)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                let text = column < row.count ? row[column] : ""
                let content = NSMutableAttributedString(attributedString: inlineAttributed(
                    text, baseSize: baseSize, baseColor: baseColor,
                    forceFont: rowIndex == 0 ? NSFont.systemFont(ofSize: baseSize, weight: .semibold) : nil,
                    inlineAssessments: inlineAssessments))
                content.append(NSAttributedString(string: "\n"))
                content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
                result.append(content)
            }
        }
        if rows.count > 200 {
            result.append(NSAttributedString(string: "…还有 \(rows.count - 200) 行，复制可得全部\n", attributes: [
                .font: NSFont.systemFont(ofSize: max(10, baseSize - 1)),
                .foregroundColor: baseColor.withAlphaComponent(0.68)
            ]))
        }
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendDivider(to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor) {
        result.append(NSAttributedString(
            string: String(repeating: "─", count: 40),
            attributes: [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: baseColor.withAlphaComponent(0.5)]
        ))
        result.append(NSAttributedString(string: "\n"))
    }

    private static func headingSize(_ level: Int, baseSize: CGFloat) -> CGFloat {
        switch level {
        case 1: return baseSize + 7
        case 2: return baseSize + 4
        case 3: return baseSize + 2
        case 4: return baseSize + 1
        case 5: return baseSize
        default: return baseSize - 1
        }
    }

    // MARK: 行内 Markdown（粗体/斜体/行内代码/链接）

    /// 解析行内 Markdown 为 NSAttributedString；解析失败回退纯文本。
    /// forceFont 非空时强制统一字体（用于标题），否则按行内标记（代码等宽）处理。
    private static func inlineAttributed(
        _ text: String,
        baseSize: CGFloat,
        baseColor: NSColor,
        forceFont: NSFont? = nil,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus] = [:]
    ) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: baseSize)
        if (inlineAssessments[Data(text.utf8)] ?? assess([.paragraph(text)])) == .fallback {
            return NSAttributedString(string: visibleTextWithoutLinkDestinations(text), attributes: [
                .font: forceFont ?? baseFont, .foregroundColor: baseColor
            ])
        }
        let parsed: AttributedString
        TranscriptOperationDiagnostics.parserCall(kind: "inline")
        if let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            parsed = a
        } else {
            parsed = AttributedString(text)
        }
        // Preserve semantic run boundaries before bridging: AppKit attributes
        // need not retain Swift InlinePresentationIntent or split at its edges.
        var semanticRuns: [(range: NSRange, code: Bool, strong: Bool, emphasis: Bool)] = []
        var utf16Offset = 0
        for run in parsed.runs {
            let length = String(parsed[run.range].characters).utf16.count
            let intent = run.inlinePresentationIntent
            semanticRuns.append((NSRange(location: utf16Offset, length: length),
                intent?.contains(.code) == true,
                intent?.contains(.stronglyEmphasized) == true,
                intent?.contains(.emphasized) == true))
            utf16Offset += length
        }
        let ns = NSAttributedString(parsed)
        let result = NSMutableAttributedString()
        for semantic in semanticRuns {
            ns.enumerateAttributes(in: semantic.range) { attrs, range, _ in
                let substring = (ns.string as NSString).substring(with: range)
                var font = forceFont ?? baseFont
                var bg: NSColor? = nil
                if semantic.code {
                    font = forceFont ?? NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
                    bg = baseColor.withAlphaComponent(0.15)
                }
                if semantic.strong || semantic.emphasis {
                    var traits = NSFontManager.shared.traits(of: font)
                    if semantic.strong { traits.insert(.boldFontMask) }
                    if semantic.emphasis { traits.insert(.italicFontMask) }
                    font = NSFontManager.shared.convert(font, toHaveTrait: traits)
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColor]
                if let bg { attributes[.backgroundColor] = bg }
                if let url = TranscriptExternalLink.allowedURL(attrs[.link]) {
                    attributes[TranscriptExternalLink.destination] = url
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: substring, attributes: attributes))
            }
        }
        return result
    }
}
