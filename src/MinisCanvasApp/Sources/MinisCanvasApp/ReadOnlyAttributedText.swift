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

/// 代码块标题行上的"复制代码"入口：payload 是该代码块的（已脱敏的）可见正文。
/// 点击由 Coordinator 处理（写入剪贴板），不走任何外部导航。
enum TranscriptCodeCopy {
    static let payload = NSAttributedString.Key("MinisCanvas.codeCopyPayload")
    static let linkURL = URL(string: "minis-copy://code")!
    static let label = "复制代码"
    static let copiedLabel = "✓已复制"
}

/// 代码块表面。卡片（底色 + 细边框 + 圆角）由 `ChatTranscriptNativeTextView.draw(_:)`
/// 按可见行绘制；AppKit 若自行调用块背景绘制，在转录视图里跳过，避免叠出直角方框。
final class CodeSurfaceTextBlock: NSTextBlock {
    static let cornerRadius: CGFloat = 8
    /// 代码文字距卡片左右边缘的距离。
    static let textInset: CGFloat = 12
    /// 卡片内上下留白（首行文字之上、末行文字之下）。
    static let verticalPadding: CGFloat = 8
    /// 卡片与前后正文之间的空隙。
    static let outerGap: CGFloat = 6
    /// 顶行（语言名 · 复制代码）与代码之间的空隙。
    static let headerGap: CGFloat = 4
    static let fillAlpha: CGFloat = 0.05
    static let borderAlpha: CGFloat = 0.14

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        if controlView is ChatTranscriptNativeTextView { return }
        super.drawBackground(withFrame: frameRect, in: controlView,
                             characterRange: charRange, layoutManager: layoutManager)
    }
}

/// 用户消息气泡：靠右、圆角、最大宽度约为转录列的 80%。
/// 宽度靠块左外边距（百分比）实现，文字换行由 AppKit 在窄后的内容区内完成；
/// 圆角底色由 `ChatTranscriptNativeTextView.draw(_:)` 按可见行绘制（同代码卡片的做法），
/// AppKit 若自行调用块背景绘制，在转录视图里跳过，避免叠出直角方框。
final class UserBubbleTextBlock: NSTextBlock {
    static let cornerRadius: CGFloat = 12
    /// 气泡占转录列宽度的比例上限（按文字实际宽度贴合，长消息最多到这个比例）。
    static let maxWidthFraction: CGFloat = 0.8
    /// 气泡最小宽度，避免一两个字的消息气泡过窄。
    static let minimumWidth: CGFloat = 120
    /// 气泡边缘与文字之间的水平内边距（文字缩进为阅读列 gutter，气泡向外伸出 gutter 减此值）。
    static let textInset: CGFloat = 12
    /// 气泡上下各向内收的距离，避免相邻消息的气泡首尾相接。
    static let verticalTrim: CGFloat = 3

    /// 文字换行的左侧额外缩进（由段落缩进实现，见 ChatTranscriptFormatter.applyReadingParagraphStyle；
    /// 文本块外边距在这套排版里不生效，包上实测为整栏）。气泡可见宽度由绘制层按文字实际宽度贴合。
    static let wrapInset: CGFloat = 96

    /// 几何全部由段落缩进与绘制层负责，块本身不设外边距（保留此入口，调用方不变）。
    func applyBubbleGeometry() {}

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        if controlView is ChatTranscriptNativeTextView { return }
        super.drawBackground(withFrame: frameRect, in: controlView,
                             characterRange: charRange, layoutManager: layoutManager)
    }
}

/// 当前对话的项目根目录：用于把回复里的相对路径（如 `src/a.swift:42`）识别为可点链接。
/// 由对话界面在会话切换时写入；只读、线程安全，不写入偏好或对话。
final class TranscriptPathLinkContext: @unchecked Sendable {
    static let shared = TranscriptPathLinkContext()
    private let lock = NSLock()
    private var root: URL?
    var projectRoot: URL? {
        get { lock.lock(); defer { lock.unlock() }; return root }
        set { lock.lock(); defer { lock.unlock() }; root = newValue }
    }
}

/// 路径识别时“文件是否存在”的短时缓存：渲染在主线程上反复重算，
/// 每次都对磁盘（含网络盘）做存在性检查会卡顿；缓存几十秒、有数量上限。
enum TranscriptPathExistenceCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: (exists: Bool, at: Date)] = [:]
    static let lifetime: TimeInterval = 30
    static let capacity = 2000

    static func exists(_ path: String, now: Date = Date(),
                       check: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        lock.lock()
        if let hit = entries[path], now.timeIntervalSince(hit.at) < lifetime {
            lock.unlock()
            return hit.exists
        }
        lock.unlock()
        let result = check(path)
        lock.lock()
        if entries.count >= capacity { entries.removeAll() }
        entries[path] = (result, now)
        lock.unlock()
        return result
    }

    static func resetForTesting() { lock.lock(); entries.removeAll(); lock.unlock() }
}

/// 对话正文里的本地文件链接：`file://`、以 `/` 开头的绝对路径、`~/` 路径。
/// 解析与风险判定都是纯函数（不依赖点击），点击处理只负责弹确认并执行结果。
enum TranscriptLocalFileLink {
    enum Action: Equatable {
        /// 已存在的普通文件，且不是可执行/自动运行类型：用系统默认程序打开。
        case open(URL)
        /// 已存在的文件夹：在 Finder 中显示。
        case revealFolder(URL)
        /// 可执行、脚本、安装包等类型或带执行位：只在 Finder 中显示，不运行。
        case revealBlocked(URL, reason: String)
        /// 路径不存在。
        case missing(URL)
    }

    static let blockedExtensions: Set<String> = [
        "app", "command", "sh", "zsh", "bash", "tool", "pkg", "mpkg", "dmg",
        "terminal", "workflow", "scpt", "applescript", "jar", "py", "rb", "pl",
        "js", "exe", "webloc", "inetloc", "fileloc", "bat", "cmd", "ps1", "vbs",
        "jnlp", "action", "osax", "service", "wflow", "lnk"
    ]

    /// 脚本类：不直接运行，也不交给默认程序，显式用文本编辑器打开查看。
    /// app、command、pkg 等其余被拦截类型仍只在 Finder 中显示。
    static let textEditorExtensions: Set<String> = [
        "sh", "zsh", "bash", "command", "tool", "py", "rb", "pl", "js",
        "scpt", "applescript", "bat", "cmd", "ps1", "vbs"
    ]

    /// 用户点“打开”时的处置：普通文件交给系统，脚本用文本编辑器，其余可执行类型只在 Finder 显示。
    enum OpenDisposition: Equatable {
        case systemOpen
        case textEditor
        case revealOnly
    }

    static func openDisposition(for url: URL, fileManager: FileManager = .default) -> OpenDisposition {
        let resolved = url.resolvingSymlinksInPath()
        let extensions = [url.pathExtension, resolved.pathExtension].map { $0.lowercased() }
        if extensions.contains(where: { blockedExtensions.contains($0) }) {
            // 链接与真实目标都必须是脚本类，才允许文本编辑器打开。
            if extensions.allSatisfy({ textEditorExtensions.contains($0) }) { return .textEditor }
            return .revealOnly
        }
        let permissions = (try? fileManager.attributesOfItem(atPath: resolved.path))?[.posixPermissions] as? NSNumber
        if let mode = permissions?.intValue, mode & 0o111 != 0 { return .revealOnly }
        return .systemOpen
    }

    /// 用 TextEdit 显式打开（不运行）。
    @MainActor static func openInTextEditor(_ url: URL) -> Bool {
        let editor = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard FileManager.default.fileExists(atPath: editor.path) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: editor,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        return true
    }

    // Session-scoped, like web host confirmation: never persisted.
    @MainActor private static var confirmedPathsBySession: [UUID: Set<String>] = [:]

    @MainActor static func isConfirmed(path: String, sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return confirmedPathsBySession[sessionID]?.contains(path) == true
    }

    @MainActor static func confirm(path: String, sessionID: UUID?) {
        guard let sessionID else { return }
        confirmedPathsBySession[sessionID, default: []].insert(path)
    }

    /// 把链接目标解析成标准化的本地文件 URL；非本地目标（含 http/https 与其它 scheme）返回 nil。
    static func resolve(
        _ value: Any?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return nil }
        let path: String
        if let scheme = url.scheme?.lowercased() {
            guard scheme == "file" else { return nil }
            path = url.path
        } else {
            // 排除 //host/path 这类网络路径引用。
            guard (url.host ?? "").isEmpty else { return nil }
            let raw = url.path
            if raw.hasPrefix("/") {
                path = raw
            } else if raw == "~" {
                path = homeDirectory.path
            } else if raw.hasPrefix("~/") {
                path = homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).path
            } else {
                return nil
            }
        }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func action(for url: URL, fileManager: FileManager = .default) -> Action {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing(url)
        }
        // 链接本身与其指向的真实目标，任何一个命中拦截扩展名都拦截。
        let resolved = url.resolvingSymlinksInPath()
        let extensions = [url.pathExtension, resolved.pathExtension].map { $0.lowercased() }
        if let hit = extensions.first(where: { blockedExtensions.contains($0) }) {
            return .revealBlocked(url, reason: "“.\(hit)”属于可执行或会自动运行的类型")
        }
        if isDirectory.boolValue { return .revealFolder(url) }
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            return .revealBlocked(url, reason: "目标不是普通文件")
        }
        let permissions = (try? fileManager.attributesOfItem(atPath: resolved.path))?[.posixPermissions] as? NSNumber
        if let mode = permissions?.intValue, mode & 0o111 != 0 {
            return .revealBlocked(url, reason: "文件带有执行权限")
        }
        return .open(url)
    }

    static func confirmationText(for action: Action) -> String {
        switch action {
        case .open(let url):
            return "将使用系统默认程序打开：\n\(url.path)"
        case .revealFolder(let url):
            return "将在 Finder 中显示文件夹：\n\(url.path)"
        case .revealBlocked(let url, let reason):
            if openDisposition(for: url) == .textEditor {
                return "\(reason)，不会运行，将用文本编辑器打开查看：\n\(url.path)"
            }
            return "\(reason)，不会直接运行，将改为在 Finder 中显示：\n\(url.path)"
        case .missing(let url):
            return "路径不存在：\n\(url.path)"
        }
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
/// ⌘F 查找：转录正文的 NSTextView 在创建时登记，对话区的快捷键据此打开查找栏。
@MainActor
enum TranscriptFindRouter {
    private static weak var transcriptTextView: NSTextView?

    static func register(_ textView: NSTextView) { transcriptTextView = textView }

    /// 打开（或聚焦）当前对话正文的查找栏。没有可用的正文视图时返回 false。
    @discardableResult
    static func showFindInterface() -> Bool {
        guard let textView = transcriptTextView, let window = textView.window else { return false }
        window.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
        return true
    }
}

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
        // 在副本上原地改：只有属性被过滤、或需要换成占位文本的 run 才动，
        // 其余 run 不再逐个重建（长回复流式时这是每个片段的热点）。
        let result = NSMutableAttributedString(attributedString: source)
        let allowed: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .backgroundColor, .paragraphStyle,
            .kern, .underlineStyle, .strikethroughStyle, .baselineOffset
        ]
        let fullRange = NSRange(location: 0, length: source.length)
        let nsText = source.string as NSString
        let hasObjectMarker = nsText.range(of: "\u{FFFC}", options: .literal).location != NSNotFound
        var placeholders: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        source.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var safeAttributes = attributes.filter { allowed.contains($0.key) }
            if let marker = attributes[ChatInlineToolGap.marker] as? String,
               ChatInlineToolGap.isMarkerID(marker) {
                safeAttributes[ChatInlineToolGap.marker] = marker
            }
            if let code = attributes[TranscriptCodeCopy.payload] as? String {
                safeAttributes[TranscriptCodeCopy.payload] = code
                safeAttributes[.link] = TranscriptCodeCopy.linkURL
            } else if let url = TranscriptExternalLink.allowedURL(attributes[TranscriptExternalLink.destination]) {
                safeAttributes[TranscriptExternalLink.destination] = url
                safeAttributes[.link] = url
            } else if let file = TranscriptLocalFileLink.resolve(attributes[TranscriptExternalLink.destination]) {
                safeAttributes[TranscriptExternalLink.destination] = file
                safeAttributes[.link] = file
            }
            // U+FFFC is AppKit's object-replacement marker and can arrive
            // without a well-formed .attachment attribute after persistence.
            let hidden = attributes[.attachment] != nil
                || (hasObjectMarker
                    && nsText.range(of: "\u{FFFC}", options: .literal, range: range).location != NSNotFound)
            if !NSDictionary(dictionary: attributes).isEqual(to: safeAttributes) {
                result.setAttributes(safeAttributes, range: range)
            }
            if hidden { placeholders.append((range, safeAttributes)) }
        }
        for item in placeholders.reversed() {
            result.replaceCharacters(in: item.range, with: NSAttributedString(
                string: "[附件内容已隐藏]", attributes: item.attributes))
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
        ThemeNativeTextColors.apply(to: textView)
        textView.delegate = coordinator
        if transcriptUpdate != nil {
            // 对话正文支持原生查找栏（⌘F，输入即搜）。
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            TranscriptFindRouter.register(textView)
        }
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
        // textStorage.length 是 O(1)；attributedString() 会把全文拷贝一份。
        let contentLength = textView.textStorage?.length ?? 0
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
            guard charIndex >= 0, charIndex < textView.attributedString().length else { return true }
            if let code = textView.attributedString()
                .attribute(TranscriptCodeCopy.payload, at: charIndex, effectiveRange: nil) as? String {
                copyCode(code, at: charIndex, in: textView)
                return true
            }
            let destination = textView.attributedString()
                .attribute(TranscriptExternalLink.destination, at: charIndex, effectiveRange: nil)
            if let url = TranscriptExternalLink.allowedURL(destination), let host = url.host {
                openWebLink(url, host: host, in: textView)
            } else if let file = TranscriptLocalFileLink.resolve(destination) {
                openLocalFile(file, in: textView)
            }
            // Always consume AppKit's default navigation, including cancellation.
            return true
        }

        /// 复制代码块并把入口文字短暂改成"已复制"（等长替换，不影响转录的增量更新位置）。
        @MainActor private func copyCode(_ code: String, at charIndex: Int, in textView: NSTextView) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            guard let storage = textView.textStorage else { return }
            var effective = NSRange()
            _ = storage.attribute(TranscriptCodeCopy.payload, at: charIndex, effectiveRange: &effective)
            let label = TranscriptCodeCopy.label as NSString
            let copied = TranscriptCodeCopy.copiedLabel as NSString
            guard effective.length == label.length,
                  (storage.string as NSString).substring(with: effective) == TranscriptCodeCopy.label,
                  copied.length == label.length else { return }
            let range = effective
            let attributes = storage.attributes(at: range.location, effectiveRange: nil)
            storage.replaceCharacters(in: range,
                with: NSAttributedString(string: TranscriptCodeCopy.copiedLabel, attributes: attributes))
            Task { @MainActor [weak textView] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let storage = textView?.textStorage,
                      NSMaxRange(range) <= storage.length,
                      (storage.string as NSString).substring(with: range) == TranscriptCodeCopy.copiedLabel
                else { return }
                let attributes = storage.attributes(at: range.location, effectiveRange: nil)
                storage.replaceCharacters(in: range,
                    with: NSAttributedString(string: TranscriptCodeCopy.label, attributes: attributes))
            }
        }

        @MainActor private func openWebLink(_ url: URL, host: String, in textView: NSTextView) {
            if hasConfirmedLink(to: host) {
                NSWorkspace.shared.open(url)
                return
            }
            guard !confirmingLink, let window = textView.window else { return }
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
        }

        @MainActor private func openLocalFile(_ url: URL, in textView: NSTextView) {
            let action = TranscriptLocalFileLink.action(for: url)
            let sessionID = linkSessionID
            let alreadyConfirmed = TranscriptLocalFileLink.isConfirmed(path: url.path, sessionID: sessionID)
            if case .missing = action {
                presentNotice(TranscriptLocalFileLink.confirmationText(for: action), title: "无法打开", in: textView)
                return
            }
            if alreadyConfirmed {
                perform(action)
                if case .revealBlocked(let blockedURL, _) = action,
                   TranscriptLocalFileLink.openDisposition(for: blockedURL) != .textEditor {
                    presentNotice(TranscriptLocalFileLink.confirmationText(for: action), title: "已改为在 Finder 中显示", in: textView)
                }
                return
            }
            guard !confirmingLink, let window = textView.window else { return }
            confirmingLink = true
            let alert = NSAlert()
            alert.messageText = "打开本地文件？"
            alert.informativeText = TranscriptLocalFileLink.confirmationText(for: action)
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "继续")
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.confirmingLink = false
                guard response == .alertSecondButtonReturn else { return }
                TranscriptLocalFileLink.confirm(path: url.path, sessionID: sessionID)
                self?.perform(action)
            }
        }

        @MainActor private func perform(_ action: TranscriptLocalFileLink.Action) {
            switch action {
            case .open(let url):
                NSWorkspace.shared.open(url)
            case .revealBlocked(let url, _):
                // 脚本类用文本编辑器打开查看（不运行），其余可执行类型只在访达显示。
                if TranscriptLocalFileLink.openDisposition(for: url) == .textEditor,
                   TranscriptLocalFileLink.openInTextEditor(url) {
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .revealFolder(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .missing:
                break
            }
        }

        @MainActor private func presentNotice(_ text: String, title: String, in textView: NSTextView) {
            guard !confirmingLink, let window = textView.window else { return }
            confirmingLink = true
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window) { [weak self] _ in self?.confirmingLink = false }
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
///
/// 块级缓存：解析仍整篇做（行扫描，便宜），但每个已解析块的富文本结果按
/// （块值 + 字号 + 基色 + 流式标记 + 项目根）缓存。块输出只取决于这些输入，
/// 所以命中与重建逐字节一致；流式时只有内容变化的最后一块会重建。
/// 含 NSTextBlock/NSTextTable 的块（代码块、表格）和分隔线不缓存，避免同一
/// 对象在一篇文档里出现两次。
final class MarkdownBlockRenderCache: @unchecked Sendable {
    struct Key: Hashable {
        let block: MinisCore.MarkdownBlock
        let baseSize: CGFloat
        let baseColor: NSColor
        let isStreaming: Bool
        let projectRoot: String?
    }
    struct Value {
        let attributed: NSAttributedString
        let sawLink: Bool
        let malformed: Bool
        let createdAt: Date
    }

    static let capacity = 2048
    /// 与路径存在性缓存同寿命，避免已关闭块里的文件链接状态长期过期。
    static let lifetime: TimeInterval = TranscriptPathExistenceCache.lifetime

    private let lock = NSLock()
    private var current: [Key: Value] = [:]
    private var previous: [Key: Value] = [:]
    private var hits = 0
    private var misses = 0

    var hitCount: Int { lock.lock(); defer { lock.unlock() }; return hits }
    var missCount: Int { lock.lock(); defer { lock.unlock() }; return misses }

    func value(for key: Key, now: Date = Date()) -> Value? {
        lock.lock(); defer { lock.unlock() }
        if let value = current[key] ?? previous[key],
           now.timeIntervalSince(value.createdAt) < Self.lifetime {
            hits += 1
            return value
        }
        misses += 1
        return nil
    }

    func store(_ value: Value, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if current.count >= Self.capacity {
            previous = current
            current = [:]
        }
        current[key] = value
    }
}

enum MarkdownAttributedTextBuilder {

    private static func inlineTexts(of block: MinisCore.MarkdownBlock) -> [String] {
        switch block {
        case .heading(_, let text), .paragraph(let text), .blockquote(let text):
            return [text]
        case .list(let items, _):
            return items
        case .nestedList(let items):
            return items.map(\.text)
        case .table(let header, let rows):
            return header + rows.flatMap { $0 }
        case .codeBlock(_, _), .divider:
            return []
        }
    }

    private static func isCacheable(_ block: MinisCore.MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .blockquote, .list, .nestedList: return true
        case .codeBlock, .table, .divider: return false
        }
    }

    /// 带块缓存的渲染：与无缓存路径逐字节一致（块输出彼此独立，
    /// normalizedLeading 只按 run 处理，逐块应用等于整体应用）。
    private static func renderStateCached(
        blocks: [MinisCore.MarkdownBlock], baseSize: CGFloat, baseColor: NSColor,
        isStreaming: Bool, cache: MarkdownBlockRenderCache
    ) -> ReadOnlyAttributedTextRenderState {
        var inlineAssessments: [Data: ReadOnlyAttributedTextStatus] = [:]
        let projectRoot = TranscriptPathLinkContext.shared.projectRoot?.path
        let combined = NSMutableAttributedString()
        var sawLink = false
        var malformed = false
        for block in blocks {
            let cacheable = isCacheable(block)
            let key = MarkdownBlockRenderCache.Key(
                block: block, baseSize: baseSize, baseColor: baseColor,
                isStreaming: isStreaming, projectRoot: projectRoot)
            if cacheable, let hit = cache.value(for: key) {
                combined.append(hit.attributed)
                sawLink = sawLink || hit.sawLink
                malformed = malformed || hit.malformed
                continue
            }
            var blockLink = false
            var blockMalformed = false
            for text in inlineTexts(of: block) {
                let textKey = Data(text.utf8)
                let status: ReadOnlyAttributedTextStatus
                if let existing = inlineAssessments[textKey] {
                    status = existing
                } else {
                    status = assessInline(text, isStreaming: isStreaming)
                    inlineAssessments[textKey] = status
                }
                blockLink = blockLink || status == .sanitized
                blockMalformed = blockMalformed || status == .fallback
            }
            let rendered = attributed(from: [block], baseSize: baseSize, baseColor: baseColor,
                                      inlineAssessments: inlineAssessments)
            if cacheable {
                cache.store(.init(attributed: rendered, sawLink: blockLink,
                                  malformed: blockMalformed, createdAt: Date()), for: key)
            }
            combined.append(rendered)
            sawLink = sawLink || blockLink
            malformed = malformed || blockMalformed
        }
        let assessment: ReadOnlyAttributedTextStatus = malformed ? .fallback : (sawLink ? .sanitized : .rendered)
        if assessment == .fallback {
            combined.append(NSAttributedString(string: "\n" + (assessment.userMessage ?? ""), attributes: [
                .font: NSFont.systemFont(ofSize: max(10, baseSize - 1)),
                .foregroundColor: secondaryColor(baseColor, alpha: 0.68)
            ]))
        }
        return ReadOnlyAttributedTextRenderState(attributedString: combined, status: assessment)
    }

    /// 生产渲染入口：解析结果和状态一起返回，避免 malformed 输入被静默吞掉。
    static func renderState(
        content: String,
        isMarkdown: Bool,
        baseSize: CGFloat = 13,
        baseColor: NSColor = .textColor,
        isStreaming: Bool = false,
        blockCache: MarkdownBlockRenderCache? = nil
    ) -> ReadOnlyAttributedTextRenderState {
        guard isMarkdown else {
            return ReadOnlyAttributedTextRenderState(
                attributedString: buildPlain(content: content, baseSize: baseSize, baseColor: baseColor),
                status: .rendered
            )
        }

        let perf = PerformanceSignposts.begin(.transcriptMarkdownBuild); defer { perf.end() }
        TranscriptOperationDiagnostics.parserCall(kind: "block")
        let blocks = MinisCore.MarkdownParser.parse(content)
        if let blockCache {
            return renderStateCached(blocks: blocks, baseSize: baseSize, baseColor: baseColor,
                                     isStreaming: isStreaming, cache: blockCache)
        }
        // Reuse only byte-identical inline safety results within this render.
        var inlineAssessments: [Data: ReadOnlyAttributedTextStatus] = [:]
        let assessment = assess(blocks, inlineAssessments: &inlineAssessments, isStreaming: isStreaming)
        let rendered = NSMutableAttributedString(attributedString:
            attributed(from: blocks, baseSize: baseSize, baseColor: baseColor,
                inlineAssessments: inlineAssessments))
        if assessment == .fallback {
            rendered.append(NSAttributedString(string: "\n" + (assessment.userMessage ?? ""), attributes: [
                .font: NSFont.systemFont(ofSize: max(10, baseSize - 1)),
                .foregroundColor: secondaryColor(baseColor, alpha: 0.68)
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
    static func build(content: String, isMarkdown: Bool, baseSize: CGFloat = 13, baseColor: NSColor = .textColor,
                      isStreaming: Bool = false, blockCache: MarkdownBlockRenderCache? = nil) -> NSAttributedString {
        renderState(content: content, isMarkdown: isMarkdown, baseSize: baseSize, baseColor: baseColor,
                    isStreaming: isStreaming, blockCache: blockCache).attributedString
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
        inlineAssessments: inout [Data: ReadOnlyAttributedTextStatus],
        isStreaming: Bool = false
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
            case .nestedList(let items):
                inlineTexts = items.map(\.text)
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
                    status = assessInline(text, isStreaming: isStreaming)
                    inlineAssessments[key] = status
                }
                sawLink = sawLink || status == .sanitized
                malformed = malformed || status == .fallback
            }
        }
        if malformed { return .fallback }
        return sawLink ? .sanitized : .rendered
    }

    private static func assessInline(_ text: String, isStreaming: Bool = false) -> ReadOnlyAttributedTextStatus {
        var sawLink = false
        var malformed = false
        TranscriptOperationDiagnostics.parserCall(kind: "assessment-inline", observerOnly: true)
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            for run in parsed.runs {
                if let url = run.link, TranscriptExternalLink.allowedURL(url) == nil,
                   TranscriptLocalFileLink.resolve(url) == nil {
                    sawLink = true
                }
            }
        } else {
            malformed = true
        }
        // An odd inline delimiter is a common streaming/malformed state.
        // Treating it as plain text is deterministic and keeps the source visible.
        // 行内代码里的 * 与反引号是字面内容，不参与配对；流式输出中未闭合的反引号
        // 只是"还没写完"，完成后才判断。
        let (outside, hasUnclosedBacktick) = Self.removingInlineCodeSpans(text)
        // A symbol-only value between a value separator and a value terminator
        // has no strong content. Do not split its run into many empty pairs.
        // Ambiguous Markdown openers keep the original unmatched-strong guard.
        var strongPairs = 0
        var originalStrongPairs = 0
        var cursor = outside.startIndex
        while cursor < outside.endIndex {
            guard outside[cursor] == "*" else { cursor = outside.index(after: cursor); continue }
            let start = cursor
            var length = 0
            while cursor < outside.endIndex, outside[cursor] == "*" {
                length += 1
                cursor = outside.index(after: cursor)
            }
            let before = start == outside.startIndex ? nil : outside[outside.index(before: start)]
            let after = cursor == outside.endIndex ? nil : outside[cursor]
            let valuePrefix = before.map { "=:：".contains($0) } ?? false
            let valueEnd = after.map { $0.isWhitespace || ";；".contains($0) } ?? true
            let literalRun = length > 2 && valuePrefix && valueEnd && strongPairs % 2 == 0
            originalStrongPairs += length / 2
            if !literalRun { strongPairs += length / 2 }
        }
        // Discounting a literal run must never turn an originally balanced
        // paragraph into a new imbalance (including a run closing emphasis).
        let unbalancedStrong = originalStrongPairs % 2 != 0 && strongPairs % 2 != 0
        if (hasUnclosedBacktick && !isStreaming) || unbalancedStrong || hasMalformedLinkSyntax(text) {
            malformed = true
        }
        if malformed { return .fallback }
        return sawLink ? .sanitized : .rendered
    }

    /// 去掉成对闭合的行内代码（按反引号个数配对），返回剩余文本与"是否有未闭合的反引号"。
    /// 被去掉的位置留一个占位字符，避免两侧的 `*` 被误并成一串。
    static func removingInlineCodeSpans(_ text: String) -> (outside: String, hasUnclosedBacktick: Bool) {
        guard text.contains("`") else { return (text, false) }
        let chars = Array(text)
        var result = ""
        var i = 0
        var unclosed = false
        while i < chars.count {
            guard chars[i] == "`" else { result.append(chars[i]); i += 1; continue }
            var run = 0
            while i + run < chars.count, chars[i + run] == "`" { run += 1 }
            var j = i + run
            var closeAt: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    var n = 0
                    while j + n < chars.count, chars[j + n] == "`" { n += 1 }
                    if n == run { closeAt = j; break }
                    j += n
                } else {
                    j += 1
                }
            }
            if let closeAt {
                result.append("\u{FFFC}")
                i = closeAt + run
            } else {
                unclosed = true
                i += run
            }
        }
        return (result, unclosed)
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
            case .nestedList(let items):
                appendNestedList(items, to: result, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments)
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

    /// 次级文字色：基色按透明度派生；白字气泡底色本身只刚好满足 4.5:1（深色 4.5），
    /// 任何透明度都会掉到门槛以下，所以白色基色保持不透明，层级靠字号/字重区分。
    static func secondaryColor(_ baseColor: NSColor, alpha: CGFloat) -> NSColor {
        if let rgb = baseColor.usingColorSpace(.sRGB),
           rgb.redComponent > 0.98, rgb.greenComponent > 0.98, rgb.blueComponent > 0.98 {
            return baseColor
        }
        return baseColor.withAlphaComponent(alpha)
    }

    /// 行内代码文字色：第 1 套陶土橙（浅底 #A84E2A、深底 #E08B68，对比度均 ≥4.5）。
    /// 白字气泡（底色本身是强调色）沿用基色，避免同色看不见。
    private static func inlineCodeColor(for baseColor: NSColor) -> NSColor {
        guard let rgb = baseColor.usingColorSpace(.sRGB) else { return baseColor }
        if rgb.redComponent > 0.98, rgb.greenComponent > 0.98, rgb.blueComponent > 0.98 { return baseColor }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
            ? NSColor(srgbRed: 168 / 255, green: 78 / 255, blue: 42 / 255, alpha: rgb.alphaComponent)
            : NSColor(srgbRed: 224 / 255, green: 139 / 255, blue: 104 / 255, alpha: rgb.alphaComponent)
    }

    private static func appendCode(language: String?, code: String, to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor) {
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        // 圆角卡片：外观（底色、细边框、圆角）由 ChatTranscriptNativeTextView 按行绘制，
        // 不用 NSTextBlock 的内边距排版（AppKit 只给块内第一段加内边距，首行会错位）。
        // 文字与卡片边缘的距离靠段落缩进，卡片上下留白靠首段段前、末段段后间距。
        let surface = CodeSurfaceTextBlock()
        surface.backgroundColor = baseColor.withAlphaComponent(CodeSurfaceTextBlock.fillAlpha)
        surface.setBorderColor(baseColor.withAlphaComponent(CodeSurfaceTextBlock.borderAlpha))
        func paragraphStyle(before: CGFloat, after: CGFloat) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.textBlocks = [surface]
            style.firstLineHeadIndent = CodeSurfaceTextBlock.textInset
            style.headIndent = CodeSurfaceTextBlock.textInset
            style.tailIndent = -CodeSurfaceTextBlock.textInset
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            return style
        }
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseSize - 2, weight: .medium),
            // 0.72：卡片底色上仍满足次要文字 4.5:1（0.6 在浅色主题只有约 3.8）。
            .foregroundColor: secondaryColor(baseColor, alpha: 0.72),
            .paragraphStyle: paragraphStyle(before: CodeSurfaceTextBlock.outerGap + CodeSurfaceTextBlock.verticalPadding,
                                            after: CodeSurfaceTextBlock.headerGap)
        ]
        if let language, !language.isEmpty {
            result.append(NSAttributedString(string: language + "  ·  ", attributes: headerAttributes))
        }
        // 就地复制入口：随代码块出现在卡片顶行，点击即复制该代码块正文。
        var copyAttributes = headerAttributes
        copyAttributes[TranscriptCodeCopy.payload] = code
        result.append(NSAttributedString(string: TranscriptCodeCopy.label, attributes: copyAttributes))
        result.append(NSAttributedString(string: "\n", attributes: headerAttributes))
        let codeAttributes: [NSAttributedString.Key: Any] = [
            .font: codeFont, .foregroundColor: baseColor,
            .paragraphStyle: paragraphStyle(before: 0, after: 0)
        ]
        var lastAttributes = codeAttributes
        lastAttributes[.paragraphStyle] = paragraphStyle(
            before: 0, after: CodeSurfaceTextBlock.verticalPadding + CodeSurfaceTextBlock.outerGap)
        let body = code as NSString
        let lastBreak = body.range(of: "\n", options: .backwards)
        if lastBreak.location == NSNotFound {
            result.append(NSAttributedString(string: code + "\n", attributes: lastAttributes))
        } else {
            result.append(NSAttributedString(string: body.substring(to: NSMaxRange(lastBreak)), attributes: codeAttributes))
            result.append(NSAttributedString(string: body.substring(from: NSMaxRange(lastBreak)) + "\n", attributes: lastAttributes))
        }
    }

    private static func appendBlockquote(_ text: String, to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]) {
        let para = NSMutableParagraphStyle()
        para.headIndent = 12
        let m = NSMutableAttributedString(attributedString: inlineAttributed(text, baseSize: baseSize, baseColor: secondaryColor(baseColor, alpha: 0.75), inlineAssessments: inlineAssessments))
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
                attributes: [.font: NSFont.systemFont(ofSize: baseSize, weight: .semibold), .foregroundColor: secondaryColor(baseColor, alpha: 0.75)]
            ))
            result.append(inlineAttributed(item, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments))
            result.append(NSAttributedString(string: "\n"))
        }
        result.append(NSAttributedString(string: "\n"))
    }

    /// 嵌套列表：按层级缩进；有序项使用解析出的序号（保留起始序号，空行不重新编号）。
    private static func appendNestedList(_ items: [MarkdownListItem], to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]) {
        let bullets = ["•", "◦", "▪"]
        for item in items {
            let marker = item.ordered ? "\(item.number). " : bullets[min(item.level, bullets.count - 1)] + " "
            let line = NSMutableAttributedString(
                string: marker,
                attributes: [.font: NSFont.systemFont(ofSize: baseSize, weight: .semibold), .foregroundColor: secondaryColor(baseColor, alpha: 0.75)]
            )
            line.append(inlineAttributed(item.text, baseSize: baseSize, baseColor: baseColor, inlineAssessments: inlineAssessments))
            line.append(NSAttributedString(string: "\n"))
            if item.level > 0 {
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = CGFloat(item.level) * 20
                style.headIndent = CGFloat(item.level) * 20 + 14
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            }
            result.append(line)
        }
        result.append(NSAttributedString(string: "\n"))
    }

    static func tableColumnCount(_ rows: [[String]]) -> Int {
        rows.map(\.count).max() ?? 0
    }

    private static func appendTable(_ header: [String], rows: [[String]], to result: NSMutableAttributedString, baseSize: CGFloat, baseColor: NSColor,
        inlineAssessments: [Data: ReadOnlyAttributedTextStatus]) {
        guard !header.isEmpty else { return }
        let table = NSTextTable()
        let visibleRows = [header] + Array(rows.prefix(200))
        // 数据行比表头多出的单元格也要显示（与流式阶段一致）：列数取表头和可见数据行的最大值，表头缺的列留空。
        let columnCount = tableColumnCount(visibleRows)
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setValue(100, type: .percentageValueType, for: .width)
        for (rowIndex, row) in visibleRows.enumerated() {
            for column in 0..<columnCount {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                            startingColumn: column, columnSpan: 1)
                cell.setValue(100 / CGFloat(columnCount), type: .percentageValueType, for: .width)
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
                .foregroundColor: secondaryColor(baseColor, alpha: 0.68)
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
                var foreground = baseColor
                if semantic.code {
                    // 行内代码：不铺灰底（灰底按整行高画，折行时会断成两块），只用等宽字 + 强调色区分。
                    font = forceFont ?? NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
                    foreground = inlineCodeColor(for: baseColor)
                }
                if semantic.strong || semantic.emphasis {
                    var traits = NSFontManager.shared.traits(of: font)
                    if semantic.strong { traits.insert(.boldFontMask) }
                    if semantic.emphasis { traits.insert(.italicFontMask) }
                    font = NSFontManager.shared.convert(font, toHaveTrait: traits)
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
                if let url = TranscriptExternalLink.allowedURL(attrs[.link]) {
                    attributes[TranscriptExternalLink.destination] = url
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                } else if let file = TranscriptLocalFileLink.resolve(attrs[.link]) {
                    attributes[TranscriptExternalLink.destination] = file
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: substring, attributes: attributes))
            }
        }
        linkifyBareTargets(result)
        return result
    }

    // MARK: 裸网址与文件路径

    private static let bareURLExpression = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"'`\]\)）】，。；！？、]+"#)

    private static let barePathExpression: NSRegularExpression? = {
        let forbidden = #"\s<>"'`|*?:;,，。；！？、（）()\[\]{}“”‘’"#
        let absolute = "~?/[^\(forbidden)]+"
        // 路径字符集放宽到 Unicode（中文文件名、带重音字符等）。
        let relativeWithSlash = #"(?:\.{1,2}/)?[\p{L}\p{N}_@+\-][\p{L}\p{N}_.@+\-]*(?:/[\p{L}\p{N}_.@+\-]+)+"#
        let bareFile = #"[\p{L}\p{N}_@+\-]+(?:\.[\p{L}\p{N}_@+\-]+)*\.[A-Za-z][A-Za-z0-9]{0,7}"#
        let pattern = #"(?<![\p{L}\p{N}_./~@:\-])(?:"# + absolute + "|" + relativeWithSlash + "|" + bareFile
            + #")(?::[0-9]+(?::[0-9]+)?)?"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// 引号、反引号或中文引号包住的路径（可含空格），捕获组 1 为路径本身。
    private static let quotedPathExpression = try? NSRegularExpression(
        pattern: #"["'`“‘「]((?:~/|/|[\p{L}\p{N}_.][^"'`”’」\n]*/)[^"'`”’」\n]*[^"'`”’」\n/])["'`”’」]"#)

    private static let lineSuffixExpression = try? NSRegularExpression(pattern: #":[0-9]+(?::[0-9]+)?$"#)

    /// 把回复里的裸 http(s) 网址和 `path/file.swift:42` 这类文件路径变成可点链接。
    /// 路径只在文件真实存在时才可点（相对路径相对当前项目根）；点击沿用已有的确认与
    /// 可执行文件拦截规则。已经是链接的文字不动。
    private static func linkifyBareTargets(_ result: NSMutableAttributedString) {
        let text = result.string
        guard text.contains("/") || text.contains(".") else { return }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        func overlapsLink(_ range: NSRange) -> Bool {
            var found = false
            result.enumerateAttribute(TranscriptExternalLink.destination, in: range) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }
        func apply(_ url: URL, to range: NSRange) {
            result.addAttributes([
                TranscriptExternalLink.destination: url,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }

        var claimed: [NSRange] = []
        if let expression = bareURLExpression {
            for match in expression.matches(in: text, range: full) {
                var range = match.range
                while range.length > 0, ".,;:!?".contains(ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))) {
                    range.length -= 1
                }
                guard range.length > 0,
                      let url = TranscriptExternalLink.allowedURL(ns.substring(with: range)) else { continue }
                if overlapsLink(range) {
                    // 上游解析把裸网址连同后面的中文标点和文字一起吞成了更长的链接：
                    // 显示文字就是网址原文加后缀时，截回网址本身重设。其他已有链接不动。
                    var effective = NSRange(location: 0, length: 0)
                    guard result.attribute(TranscriptExternalLink.destination, at: range.location,
                                           effectiveRange: &effective) != nil,
                          effective.location == range.location, effective.length > range.length,
                          NSMaxRange(effective) <= ns.length,
                          ns.substring(with: effective).hasPrefix(ns.substring(with: range)) else { continue }
                    result.removeAttribute(TranscriptExternalLink.destination, range: effective)
                    result.removeAttribute(.underlineStyle, range: effective)
                }
                apply(url, to: range)
                claimed.append(range)
            }
        }

        let projectRoot = TranscriptPathLinkContext.shared.projectRoot
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 含空格的路径只认引号/反引号包住且文件真实存在的。
        if let quoted = quotedPathExpression {
            var quotedChecked = 0
            for match in quoted.matches(in: text, range: full) where match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                guard range.location != NSNotFound, range.length > 0,
                      !overlapsLink(range),
                      !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                quotedChecked += 1
                if quotedChecked > 8 { break }
                let token = ns.substring(with: range)
                let path: String
                if token.hasPrefix("/") {
                    path = token
                } else if token.hasPrefix("~/") {
                    path = home.appendingPathComponent(String(token.dropFirst(2))).path
                } else if let projectRoot {
                    path = projectRoot.appendingPathComponent(token).path
                } else {
                    continue
                }
                guard TranscriptPathExistenceCache.exists(path),
                      let url = TranscriptLocalFileLink.resolve(URL(fileURLWithPath: path)) else { continue }
                apply(url, to: range)
                claimed.append(range)
            }
        }

        guard let expression = barePathExpression else { return }
        var checked = 0
        for match in expression.matches(in: text, range: full) {
            var range = match.range
            if claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            while range.length > 1, ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "." {
                range.length -= 1
            }
            var token = ns.substring(with: range)
            if let suffix = lineSuffixExpression?.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) {
                token = (token as NSString).substring(to: suffix.range.location)
            }
            guard !token.isEmpty, !overlapsLink(range) else { continue }
            checked += 1
            if checked > 24 { break }
            let path: String
            if token.hasPrefix("/") {
                path = token
            } else if token.hasPrefix("~/") {
                path = home.appendingPathComponent(String(token.dropFirst(2))).path
            } else if let projectRoot {
                path = projectRoot.appendingPathComponent(token).path
            } else {
                continue
            }
            guard TranscriptPathExistenceCache.exists(path),
                  let url = TranscriptLocalFileLink.resolve(URL(fileURLWithPath: path)) else { continue }
            apply(url, to: range)
        }
    }
}
