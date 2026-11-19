import SwiftUI
import AppKit
import os

/// D-PERF-01: fixed, content-free intervals for the mounted native composer.
/// The callback interval includes the AppKit string snapshot and the real
/// draft binding setter; the child intervals let Instruments attribute cost.
private enum ComposerInputSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.miniscanvas.MinisCanvas", category: "ComposerPerformance"
    )
    static let callback = StaticString("ComposerTextDidChange")
    static let textSnapshot = StaticString("ComposerTextSnapshot")
    static let draftBinding = StaticString("ComposerDraftBinding")
    static let keyDownStart = StaticString("ComposerKeyDownStart")
    static let draftCommitted = StaticString("ComposerDraftCommitted")
}

// MARK: - AJ-24 可滚动多行输入框（NSTextView 桥接）
//
// 背景：原输入框 TextField(axis:.vertical) + .lineLimit(1...4) 超过 4 行不产生滚动视图，
// 内容多时只能方向键挪光标（用户反馈：鼠标无法滚动）。
// 方案 B（NSTextView NSViewRepresentable，而非 TextEditor 包 ScrollView）：
// - 必须保留「回车发送 / ⌥⏎ 换行」；TextEditor 无法拦截回车键（总是插入换行、无 onSubmit），
//   而 NSTextView 的 doCommandBy 可精确区分普通回车（发送，消费事件）与 ⌥⏎（换行，交给默认）。
// - NSTextView 天然滚动，包固定高度 NSScrollView 即可出现滚动条，鼠标滚轮可查看全部内容。

/// 回车键行为判定（纯函数，可单测）：普通回车=发送，⌥⏎ / ⇧⏎=换行。
enum ComposerReturnBinding {
    /// 回车是否应判定为「发送」（而非换行）。
    /// - optionKey == false（普通回车）→ true（发送）
    /// - optionKey == true（⌥⏎ 或 ⇧⏎，参数名沿用）→ false（换行）
    static func shouldSendOnReturn(optionKey: Bool) -> Bool {
        !optionKey
    }
}

/// Native command events emitted by the AppKit text view before it mutates
/// the draft. The optional callback lets command menus consume their keys;
/// unhandled Tab keys traverse the native window for both Composer consumers.
enum ComposerNativeKey: Equatable {
    case up
    case down
    case returnKey(option: Bool)
    case tab
    case shiftTab
    case escape
    case historySearch
}

enum ComposerNativeKeyRouting {
    static func key(
        for selector: Selector,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ComposerNativeKey? {
        switch NSStringFromSelector(selector) {
        case "moveUp:":
            return .up
        case "moveDown:":
            return .down
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:":
            // ⌥⏎ 与 ⇧⏎ 都是换行（对齐 Claude Code 的 Shift+Enter）。
            return .returnKey(option: modifierFlags.contains(.option) || modifierFlags.contains(.shift))
        case "insertTab:":
            return modifierFlags.contains(.shift) ? .shiftTab : .tab
        case "insertBacktab:":
            return .shiftTab
        case "cancelOperation:":
            return .escape
        default:
            return nil
        }
    }
}

struct ComposerPasteEvent: Equatable, Sendable {
    let text: String
    let bodyBefore: String
    let draft: PastedTextDraft
    /// 剪贴板里的文件或图片（图片已落成临时文件）。非空时按附件处理，不插入文字。
    let attachmentURLs: [URL]

    init(text: String, bodyBefore: String = "", attachmentURLs: [URL] = []) {
        self.text = text
        self.bodyBefore = bodyBefore
        self.draft = PastedTextDraft(id: UUID(), text: text, source: .pasteboard)
        self.attachmentURLs = attachmentURLs
    }

    static func editableBody(
        replacing selection: Range<String.Index>,
        in body: String
    ) -> String {
        String(body[..<selection.lowerBound]) + String(body[selection.upperBound...])
    }
}

/// 粘贴优先级（纯函数）：文件 URL → 附件；有图片且文字为空或只是一个链接 → 图片附件；
/// 有正常文字 → 按文字粘贴（Excel/Pages 复制表格时同时带图片表示，应粘文字）。
enum ComposerPasteDecision: Equatable {
    case fileAttachments
    case imageAttachment
    case text

    static func resolve(hasFileURLs: Bool, hasImage: Bool, text: String?) -> ComposerPasteDecision {
        if hasFileURLs { return .fileAttachments }
        if hasImage, isEmptyOrSingleLink(text) { return .imageAttachment }
        return .text
    }

    /// 文字为空，或整段只是一个 blob:/http(s): 链接（浏览器“复制图片”常见）。
    static func isEmptyOrSingleLink(_ text: String?) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return true }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        let lower = trimmed.lowercased()
        return lower.hasPrefix("blob:") || lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}

/// 从剪贴板取出可作为附件的内容：文件 URL 优先，其次图片数据（写成临时 PNG）。
enum ComposerPasteboardAttachments {
    /// 与 ChatAttachmentOpenTarget 的临时目录约定同根：<tmp>/MinisCanvas/ChatAttachments/
    static func defaultImageDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvas", isDirectory: true)
            .appendingPathComponent("ChatAttachments", isDirectory: true)
            .appendingPathComponent("PastedImages", isDirectory: true)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    static func hasImage(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func urls(
        from pasteboard: NSPasteboard,
        imageDirectory: URL = defaultImageDirectory()
    ) -> [URL] {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty { return files }
        return imageURLs(from: pasteboard, imageDirectory: imageDirectory)
    }

    /// 只取图片（写成临时 PNG）；调用方已按 ComposerPasteDecision 决定要走图片附件时才落盘。
    /// 剪贴板里有多张图片时全部返回；同时清理超过 1 天的旧临时图片。
    static func imageURLs(
        from pasteboard: NSPasteboard,
        imageDirectory: URL = defaultImageDirectory()
    ) -> [URL] {
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !images.isEmpty else { return [] }
        removeStaleImagesIfDue(in: imageDirectory)
        let directory = imageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return []
        }
        var urls: [URL] = []
        for (index, image) in images.enumerated() {
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            let name = images.count == 1 ? "粘贴的图片.png" : "粘贴的图片 \(index + 1).png"
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            if (try? png.write(to: destination, options: .atomic)) != nil { urls.append(destination) }
        }
        return urls
    }

    /// 清理时间戳：同一目录每个间隔最多清理一次，粘贴路径不再每次都遍历目录。
    private final class SweepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var lastSweep: [String: Date] = [:]
        func isDue(_ path: String, now: Date, interval: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let last = lastSweep[path], now.timeIntervalSince(last) < interval { return false }
            lastSweep[path] = now
            return true
        }
    }
    private static let sweepClock = SweepClock()

    /// 降频版清理：每个目录每 24 小时最多一次（App 常驻时也会隔天再清）。
    static func removeStaleImagesIfDue(in directory: URL, minimumInterval: TimeInterval = 24 * 3600, now: Date = Date()) {
        guard sweepClock.isDue(directory.path, now: now, interval: minimumInterval) else { return }
        removeStaleImages(in: directory, now: now)
    }

    /// 剪贴板里图片的原始字节快照（主线程只做取字节，不编码）：
    /// 优先 PNG / TIFF 原始数据，没有时才退回 NSImage 的 TIFF 表示。
    static func imageDataSnapshot(from pasteboard: NSPasteboard) -> [Data] {
        let raw = (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: .png) ?? item.data(forType: .tiff)
        }
        if !raw.isEmpty { return raw }
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]
        else { return [] }
        return images.compactMap { $0.tiffRepresentation }
    }

    /// 粘贴图片的临时 PNG 不会随附件移除而删除；每次粘贴时顺手清掉超过 7 天的旧目录
    /// （草稿附件重启后可恢复，期限放宽到 7 天，避免隔天恢复时文件已被清掉）。
    static func removeStaleImages(in directory: URL, olderThan age: TimeInterval = 7 * 24 * 3600, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            guard let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, now.timeIntervalSince(modified) > age else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}

enum ComposerModifiedReturnAction: Equatable {
    case send, interruptAndSend
    static func resolve(keyCode: UInt16, flags: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Self? {
        guard !hasMarkedText, keyCode == 36 else { return nil }
        let exact = flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if exact == [.command, .shift] { return .interruptAndSend }
        if exact == [.command] { return .send }
        return nil
    }
}

/// NSTextView paste hook used by both production Composer consumers.
///
/// The provider is injectable so a real `paste(_:)` event can be exercised
/// without depending on a system pasteboard server in headless tests.
final class ComposerPasteAwareTextView: NSTextView {
    var onNativeFocus: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onPasteEvent: ((ComposerPasteEvent) -> Bool)?
    var onHistorySearch: (() -> Bool)?
    var historySearchBinding: ShortcutBinding?
    var onCommandReturn: (() -> Void)?
    var onInterruptAndSend: (() -> Void)?
    weak var inputLatencyCollector: ComposerInputLatencyCollector?
    /// 注入文字来源即表示剪贴板被模拟：附件来源同时清空，避免无界面测试读到系统剪贴板里的图片或文件；
    /// 需要模拟附件时在注入文字来源之后再设置 pasteboardAttachmentProvider。
    var pasteboardStringProvider: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    } {
        didSet {
            pasteboardAttachmentProvider = { [] }
            pasteboardImageProvider = { [] }
            pasteboardHasAttachmentProvider = { false }
        }
    }
    /// 剪贴板里有没有图片或文件（只看类型，不落盘）：决定“粘贴”菜单和 ⌘V 是否可用。
    var pasteboardHasAttachmentProvider: () -> Bool = {
        ComposerPasteboardAttachments.hasImage(in: .general)
            || !ComposerPasteboardAttachments.fileURLs(from: .general).isEmpty
    }

    /// 纯文本输入框默认只在剪贴板有文字时才启用“粘贴”，剪贴板里只有图片或文件时
    /// 菜单和 ⌘V 都是灰的，paste(_:) 根本不会被调用（旅程测试 11/17 发现图片粘贴不进对话的根因）。
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)),
           isEditable, pasteboardHasAttachmentProvider() {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
    /// 剪贴板里的文件 URL（不含图片）。
    var pasteboardAttachmentProvider: () -> [URL] = {
        ComposerPasteboardAttachments.fileURLs(from: .general)
    }
    /// 剪贴板里的图片（写成临时 PNG）；只在文字为空或只是一个链接时才会被调用。
    var pasteboardImageProvider: () -> [URL] = {
        ComposerPasteboardAttachments.hasImage(in: .general)
            ? ComposerPasteboardAttachments.imageURLs(from: .general) : []
    } {
        didSet { imageProviderInjected = true }
    }
    /// 注入了同步图片来源（测试）时走同步路径；生产默认走后台编码路径。
    private var imageProviderInjected = false
    /// 生产路径：主线程只取剪贴板里的图片原始字节，PNG 编码和写盘放后台。
    var pasteboardImageSnapshotProvider: () -> [Data] = {
        ComposerPasteboardAttachments.hasImage(in: .general)
            ? ComposerPasteboardAttachments.imageDataSnapshot(from: .general) : []
    }
    /// 后台把图片字节写成临时 PNG，完成后回到主线程走同一个附件入口。
    private func pasteImageSnapshotInBackground(_ snapshot: [Data]) {
        Task { [weak self] in
            let urls = await Task.detached(priority: .userInitiated) {
                ComposerPasteboardAttachments.stageImageData(snapshot)
            }.value
            guard let self, !urls.isEmpty else { return }
            _ = self.onPasteEvent?(ComposerPasteEvent(text: "", attachmentURLs: urls))
        }
    }

    /// An ancestor's Escape outlet must finish the native conversion before
    /// considering panel dismissal. Keep the draft and the existing responder.
    @discardableResult
    func cancelMarkedCompositionForEscape() -> Bool {
        guard hasMarkedText() else { return false }
        unmarkText()
        inputContext?.discardMarkedText()
        return true
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onNativeFocus?()
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onFocusChange?(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // The focused native input owns an unmodified Escape while composing.
        // Finish it here before AppKit or another surface can consume the key.
        if event.keyCode == 53, modifiers.isEmpty, cancelMarkedCompositionForEscape() { return }
        let historyMatches: Bool
        if let binding = historySearchBinding {
            let eventBinding = ShortcutBinding(key: ShortcutBinding.keyName(fromKeyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers),
                modifiers: ShortcutModifiers(command: modifiers.contains(.command), control: modifiers.contains(.control),
                    option: modifiers.contains(.option), shift: modifiers.contains(.shift)))
            historyMatches = !binding.isEmpty && binding == eventBinding
        } else {
            historyMatches = event.keyCode == 15 && modifiers == [.control]
        }
        if !hasMarkedText(), historyMatches, onHistorySearch?() == true { return }
        // IME owns Return until composition commits. Match exact modifiers so
        // command-option/Control combinations retain AppKit editing semantics.
        switch ComposerModifiedReturnAction.resolve(
            keyCode: event.keyCode, flags: event.modifierFlags, hasMarkedText: hasMarkedText()
        ) {
        case .interruptAndSend where onInterruptAndSend != nil:
            onInterruptAndSend?(); return
        case .send where onCommandReturn != nil:
            onCommandReturn?(); return
        default: break
        }
        guard let inputLatencyCollector else {
            super.keyDown(with: event)
            return
        }
        // AppKit dispatch entry, not a hardware timestamp or presented frame.
        let scope = inputLatencyCollector.beginPhysicalKey()
        ComposerInputSignposts.signposter.emitEvent(
            ComposerInputSignposts.keyDownStart,
            "keyID=\(scope.id, privacy: .public)"
        )
        defer { inputLatencyCollector.endPhysicalKey(scope) }
        super.keyDown(with: event)
    }

    /// ⌥⇧⌘V 粘贴并匹配样式：输入框本来就是纯文本，仍要先走附件识别（文件、图片）。
    override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    /// 文件（或浏览器拖来的图片数据）拖进文字区：走附件入口，而不是把路径文字插进输入框。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        var urls = ComposerPasteboardAttachments.fileURLs(from: board)
        if urls.isEmpty, ComposerPasteboardAttachments.hasImage(in: board),
           ComposerPasteDecision.isEmptyOrSingleLink(board.string(forType: .string)) {
            urls = ComposerPasteboardAttachments.imageURLs(from: board)
        }
        if !urls.isEmpty,
           onPasteEvent?(ComposerPasteEvent(text: "", attachmentURLs: urls)) == true {
            return true
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        let fileURLs = pasteboardAttachmentProvider()
        let text = pasteboardStringProvider()
        // 文件 URL 一定走附件；图片只在文字为空或只是一个链接时才走附件，
        // 否则（如 Excel/Pages 复制表格附带图片表示）按文字粘贴。
        if !imageProviderInjected, fileURLs.isEmpty, ComposerPasteDecision.isEmptyOrSingleLink(text) {
            let snapshot = pasteboardImageSnapshotProvider()
            if !snapshot.isEmpty, onPasteEvent != nil {
                pasteImageSnapshotInBackground(snapshot)
                return
            }
        }
        let imageURLs = ComposerPasteDecision.isEmptyOrSingleLink(text) && fileURLs.isEmpty
            ? pasteboardImageProvider() : []
        let decision = ComposerPasteDecision.resolve(
            hasFileURLs: !fileURLs.isEmpty, hasImage: !imageURLs.isEmpty, text: text)
        let attachmentURLs = decision == .fileAttachments ? fileURLs : (decision == .imageAttachment ? imageURLs : [])
        if !attachmentURLs.isEmpty,
           onPasteEvent?(ComposerPasteEvent(text: "", attachmentURLs: attachmentURLs)) == true {
            return
        }
        guard let pastedText = text,
              !pastedText.isEmpty else {
            super.paste(sender)
            return
        }
        let bodyBefore: String
        if let selection = Range(selectedRange(), in: string) {
            bodyBefore = ComposerPasteEvent.editableBody(replacing: selection, in: string)
        } else {
            bodyBefore = string
        }
        let event = ComposerPasteEvent(text: pastedText, bodyBefore: bodyBefore)
        if onPasteEvent?(event) == true {
            return
        }
        super.paste(sender)
    }
}

enum NativeComposerDraftChange {
    case editing(hasMarkedText: Bool)
    case beforeSwitch(applyAcceptedText: (String) -> Void)
    case retirement
}

typealias NativeComposerDraftChangeHandler = @MainActor (String, NativeComposerDraftChange) -> Task<Void, Never>?

struct NativeComposerDraft {
    let sessionID: UUID?
    let readText: @MainActor () -> String
    let onChange: NativeComposerDraftChangeHandler
}

/// 可滚动多行输入框（NSTextView 桥接）。
/// - 内容超出固定高度（maxLines 行）时出现滚动条，鼠标滚轮可查看全部内容
/// - 普通回车 → onSend（发送）；⌥⏎ → 插入换行
/// - 绑定 draftText；拖放附件由调用方容器 .dropDestination 处理
struct ScrollableComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let onSend: () -> Void
    var onPaste: ((ComposerPasteEvent) -> Bool)? = nil
    var onCommandKey: ((ComposerNativeKey) -> Bool)? = nil
    /// 光标位置（UTF-16 偏移）变化；@ 引用按光标处判断。
    var onCursorChange: ((Int) -> Void)? = nil
    var historySearchBinding: ShortcutBinding? = nil
    var onCommandReturn: (() -> Void)? = nil
    var onInterruptAndSend: (() -> Void)? = nil
    var onStop: (() -> Bool)? = nil
    var draftSessionID: UUID? = nil
    var focusRequestID: UUID? = nil
    var inputAccessibilityIdentifier: String? = nil
    var maxLines: Int = 4
    var nativeDraft: NativeComposerDraft? = nil
    var onRememberNativeDraft: ((@escaping () -> Void) -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

    var mountedDraftSessionID: UUID? {
        if let nativeDraft { return nativeDraft.sessionID }
        return draftSessionID
    }

    /// 固定高度（maxLines 行 + 上下内边距），供调用方 .frame(height:) 使用
    static func height(for font: NSFont, maxLines: Int) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return lineHeight * CGFloat(maxLines) + 8
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        if let inputAccessibilityIdentifier {
            scrollView.setAccessibilityIdentifier(inputAccessibilityIdentifier)
        }
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ComposerPasteAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.textColor = .textColor
        ThemeNativeTextColors.apply(to: textView)
        textView.string = nativeDraft?.readText() ?? text
        textView.onHistorySearch = { context.coordinator.onCommandKey?(.historySearch) ?? false }
        textView.historySearchBinding = historySearchBinding
        textView.onCommandReturn = onCommandReturn ?? onSend
        textView.onInterruptAndSend = onInterruptAndSend
        textView.inputLatencyCollector = context.coordinator.inputLatencyCollector
        context.coordinator.onPaste = onPaste
        context.coordinator.onCommandKey = onCommandKey
        let coordinator = context.coordinator
        textView.onNativeFocus = { [weak coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.rememberFocusedDraft(in: textView)
        }
        textView.onFocusChange = onFocusChange
        textView.onPasteEvent = { [weak coordinator] event in
            coordinator?.onPaste?(event) ?? false
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let inputAccessibilityIdentifier {
            scrollView.setAccessibilityIdentifier(inputAccessibilityIdentifier)
        }
        context.coordinator.onPaste = onPaste
        context.coordinator.onCommandKey = onCommandKey
        guard let textView = scrollView.documentView as? ComposerPasteAwareTextView else { return }
        textView.onHistorySearch = { context.coordinator.onCommandKey?(.historySearch) ?? false }
        textView.historySearchBinding = historySearchBinding
        textView.onCommandReturn = onCommandReturn ?? onSend
        textView.onInterruptAndSend = onInterruptAndSend
        textView.inputLatencyCollector = context.coordinator.inputLatencyCollector
        synchronizeMountedDraft(in: textView, coordinator: context.coordinator)
        context.coordinator.parent = self
        Self.updateFontIfNeeded(font, in: textView)
        context.coordinator.applyFocusRequest(focusRequestID, in: scrollView)
    }

    func synchronizeMountedDraft(in textView: NSTextView, coordinator: Coordinator) {
        coordinator.synchronizeDraft(nativeDraft?.readText() ?? text,
                                     sessionID: mountedDraftSessionID, in: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? ComposerPasteAwareTextView else { return }
        coordinator.retire(textView)
    }

    /// A draft binding refresh does not change typography. Setting NSTextView's
    /// font again can edit attributes across the whole draft and invalidate its
    /// layout. Keep that native setter for actual typography changes only;
    /// ordinary edits keep their marked text, selection and scroll state.
    static func updateFontIfNeeded(_ font: NSFont, in textView: NSTextView) {
        guard textView.font != font else { return }
        textView.font = font
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScrollableComposerTextView
        var onPaste: ((ComposerPasteEvent) -> Bool)?
        var onCommandKey: ((ComposerNativeKey) -> Bool)?
        var lastAppliedFocusRequestID: UUID?
        private var lastDraftSessionID: UUID?
        private var retired = false
        let inputLatencyCollector = ComposerInputLatencyCollector()

        @MainActor
        init(_ parent: ScrollableComposerTextView) {
            self.parent = parent
            self.lastDraftSessionID = parent.mountedDraftSessionID
            self.onPaste = nil
            self.onCommandKey = nil
        }

        /// Streaming/layout refreshes must not reset an IME composition. A
        /// real session change discards the previous marked text while the
        /// delegate is detached, so it cannot commit into the new draft binding.
        @MainActor
        func synchronizeDraft(_ text: String, sessionID: UUID?, in textView: NSTextView) {
            if lastDraftSessionID != sessionID {
                lastDraftSessionID = sessionID
                let delegate = textView.delegate
                textView.delegate = nil
                defer { textView.delegate = delegate }
                textView.unmarkText()
                textView.string = text
                textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            } else if !textView.hasMarkedText(), textView.string != text {
                textView.string = text
            }
        }

        /// The existing Composer NSTextView is the only target. A request is
        /// consumed only after its mounted window actually accepts focus.
        @MainActor
        func applyFocusRequest(_ requestID: UUID?, in scrollView: NSScrollView) {
            guard let requestID, lastAppliedFocusRequestID != requestID,
                  let textView = scrollView.documentView as? ComposerPasteAwareTextView,
                  let window = textView.window,
                  window.makeFirstResponder(textView) else { return }
            lastAppliedFocusRequestID = requestID
        }

        @MainActor
        func rememberFocusedDraft(in textView: ComposerPasteAwareTextView) {
            guard let sessionID = parent.mountedDraftSessionID else { return }
            parent.onRememberNativeDraft? { [weak self, weak textView] in
                guard let self, let textView, !self.retired,
                      textView.delegate === self, self.parent.mountedDraftSessionID == sessionID,
                      !textView.hasMarkedText() else { return }
                _ = self.parent.nativeDraft?.onChange(textView.string, .beforeSwitch { acceptedText in
                    self.synchronizeDraft(acceptedText, sessionID: sessionID, in: textView)
                })
            }
        }

        @MainActor
        @discardableResult
        func retire(_ textView: ComposerPasteAwareTextView) -> Task<Void, Never>? {
            guard !retired else { return nil }
            retired = true
            textView.delegate = nil
            textView.onNativeFocus = nil
            textView.onFocusChange = nil
            textView.onPasteEvent = nil
            textView.onHistorySearch = nil
            textView.onCommandReturn = nil
            textView.onInterruptAndSend = nil
            textView.inputLatencyCollector = nil

            if textView.hasMarkedText() {
                let inputContext = textView.inputContext
                textView.unmarkText()
                if inputContext?.client === textView {
                    inputContext?.discardMarkedText()
                }
                return nil
            }
            return parent.nativeDraft?.onChange(textView.string, .retirement)
        }

        func textDidChange(_ notification: Notification) {
            guard !retired, let textView = notification.object as? NSTextView else { return }
            // 先报光标，再提交草稿：草稿变化的观察者读到的光标才是最新的。
            parent.onCursorChange?(textView.selectedRange().location)
            let commit = inputLatencyCollector.nextCommit()
            let physicalKeyID = commit.physicalKeyID ?? 0
            let signposter = ComposerInputSignposts.signposter
            let callback = signposter.beginInterval(ComposerInputSignposts.callback)
            let snapshot = signposter.beginInterval(ComposerInputSignposts.textSnapshot)
            let currentText = textView.string
            signposter.endInterval(ComposerInputSignposts.textSnapshot, snapshot)
            let binding = signposter.beginInterval(ComposerInputSignposts.draftBinding)
            if let nativeDraft = parent.nativeDraft {
                _ = nativeDraft.onChange(currentText, .editing(hasMarkedText: textView.hasMarkedText()))
            } else {
                parent.text = currentText
            }
            signposter.endInterval(ComposerInputSignposts.draftBinding, binding)
            signposter.emitEvent(
                ComposerInputSignposts.draftCommitted,
                "eventID=\(commit.eventID, privacy: .public) keyID=\(physicalKeyID, privacy: .public)"
            )
            signposter.endInterval(ComposerInputSignposts.callback, callback)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !retired, let textView = notification.object as? NSTextView else { return }
            parent.onCursorChange?(textView.selectedRange().location)
        }

        /// 回车键行为：普通回车 → 发送（消费事件）；⌥⏎ → 交给默认插入换行。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText(),
                  let key = ComposerNativeKeyRouting.key(
                    for: commandSelector,
                    modifierFlags: NSEvent.modifierFlags
                  ) else {
                // IME composition owns command events until marked text is committed.
                return false
            }

            if key == .escape, parent.onStop?() == true { return true }

            if onCommandKey?(key) == true {
                return true
            }

            switch key {
            case .tab:
                // Both Composer consumers use the window's key-view loop,
                // including the companion without a slash-menu callback.
                guard let window = textView.window else { return false }
                window.selectKeyView(following: textView)
                return true
            case .shiftTab:
                guard let window = textView.window else { return false }
                window.selectKeyView(preceding: textView)
                return true
            case .returnKey(let option):
                if ComposerReturnBinding.shouldSendOnReturn(optionKey: option) {
                    parent.onSend()
                    return true // 消费回车，不插入换行
                }
                // ⌥⏎ / ⇧⏎ → 返回 false，由 NSTextView 默认插入换行
                return false
            case .up, .down, .escape, .historySearch:
                return false
            }
        }
    }
}

/// 带占位符的可滚动输入框（占位符用 SwiftUI 覆盖层，空文本时显示）。
/// 供 GlobalComposerView / ChatSidebarView 两处输入框复用。
struct ComposerScrollField: View {
    @Binding var text: String
    let font: NSFont
    let placeholder: String
    let onSend: () -> Void
    var onPaste: ((ComposerPasteEvent) -> Bool)? = nil
    var onCommandKey: ((ComposerNativeKey) -> Bool)? = nil
    var onCursorChange: ((Int) -> Void)? = nil
    var historySearchBinding: ShortcutBinding? = nil
    var onCommandReturn: (() -> Void)? = nil
    var onInterruptAndSend: (() -> Void)? = nil
    var onStop: (() -> Bool)? = nil
    var persistenceFeedback: String? = nil
    var focusShortcutBinding: ShortcutBinding? = nil
    var focusSessionID: UUID? = nil
    var inputAccessibilityIdentifier: String? = nil
    /// Default retains the main composer's four-line viewport.
    var maxVisibleLines: Int = 4
    var nativeDraft: NativeComposerDraft? = nil
    var onRememberNativeDraft: ((@escaping () -> Void) -> Void)? = nil
    /// G-10：原生输入框获得/失去焦点时回调（true=获得），只用于外框描边。
    var onFocusChange: ((Bool) -> Void)? = nil
    /// A mounted Composer owns its own focus request and consumes it through
    /// the existing native NSTextView; no app-wide focus state is introduced.
    @State private var focusRequest: (id: UUID, sessionID: UUID?)?
    @Environment(\.typographyTokens) private var typography

    static func resolvedFont(
        fallback: NSFont,
        composerBodySize: CGFloat?
    ) -> NSFont {
        guard let composerBodySize else { return fallback }
        return .systemFont(ofSize: composerBodySize)
    }

    private var resolvedFont: NSFont {
        Self.resolvedFont(
            fallback: font,
            composerBodySize: typography?.composerBodySize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            editor
            if let persistenceFeedback {
                Text(persistenceFeedback)
                    .font(.caption)
                    .modifier(ReadableStatusForeground(status: .warning))
                    .accessibilityIdentifier("composer.draft.persistence-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focusSessionID) { _, _ in focusRequest = nil }
        .onDisappear { focusRequest = nil }
        .background {
            if let focusShortcutBinding {
                Button("") { focusRequest = (UUID(), focusSessionID) }
                    .shortcutKey(focusShortcutBinding)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.init(resolvedFont))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
            }
            ScrollableComposerTextView(
                text: $text,
                font: resolvedFont,
                onSend: onSend,
                onPaste: onPaste,
                onCommandKey: onCommandKey,
                onCursorChange: onCursorChange,
                historySearchBinding: historySearchBinding,
                onCommandReturn: onCommandReturn,
                onInterruptAndSend: onInterruptAndSend,
                onStop: onStop,
                draftSessionID: focusSessionID,
                focusRequestID: focusRequest?.sessionID == focusSessionID ? focusRequest?.id : nil,
                inputAccessibilityIdentifier: inputAccessibilityIdentifier,
                nativeDraft: nativeDraft,
                onRememberNativeDraft: onRememberNativeDraft,
                onFocusChange: onFocusChange
            )
                .id(focusSessionID)
                .frame(height: ScrollableComposerTextView.height(for: resolvedFont, maxLines: maxVisibleLines))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
