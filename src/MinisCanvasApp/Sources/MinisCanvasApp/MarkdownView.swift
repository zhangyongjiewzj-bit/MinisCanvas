import SwiftUI
import AppKit
import MinisCore

// MARK: - 剪贴板工具（AJ-27：代码块 / 文档全文 / 消息气泡共用）

/// 剪贴板写入边界：生产默认适配 NSPasteboard，测试可注入内存实现。
protocol PasteboardWriting: AnyObject {
    @discardableResult
    func clearContents() -> Int

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PasteboardWriting {}

/// 把文本写入系统剪贴板（NSPasteboard）。
func copyTextToClipboard(_ text: String, pasteboard: any PasteboardWriting = NSPasteboard.general) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// MARK: - 气泡悬浮操作按钮（复制/编辑 共用，AJ-27 / C4-2）
//
// 主聊天（ChatBubble）、伴随对话（同 ChatBubble）与节点面板（NodeChatBubble）
// 复用同一组件，保证复制 / 编辑按钮在各处视觉完全一致（胶囊底 + 主题强调色 + 小字号）。

/// 消息气泡悬浮操作按钮：胶囊底 + 主题强调色 + 9pt 半粗。
struct BubbleActionButton: View {
    let title: String
    let systemImage: String
    var catalogIcon: MinisIcon? = nil
    let help: String
    let action: () -> Void

    @Environment(\.themeTokens) private var theme

    private var accent: Color { theme?.aj38.accent.swiftUIColor ?? Color.accentColor }

    @ViewBuilder
    private var actionIcon: some View {
        if let catalogIcon {
            MinisIconView(catalogIcon, size: 12)
                .foregroundPalette(accent)
                .accessibilityHidden(true)
        } else {
            Image(systemName: systemImage)
        }
    }

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                actionIcon
            }
                .font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))
        )
        .foregroundStyle(accent)
        .help(help)
    }
}

/// 复制整条消息内容（气泡悬浮复制按钮）。
struct BubbleCopyButton: View {
    let content: String
    private let catalogIcon: MinisIcon?
    /// 复制动作（暴露给测试/复用；点击与 action() 等价）。
    var action: () -> Void

    init(
        content: String, pasteboard: any PasteboardWriting = NSPasteboard.general,
        catalogIcon: MinisIcon? = nil
    ) {
        self.content = content
        self.catalogIcon = catalogIcon
        self.action = { copyTextToClipboard(content, pasteboard: pasteboard) }
    }

    var body: some View {
        BubbleActionButton(title: "复制", systemImage: "doc.on.doc", catalogIcon: catalogIcon, help: "复制消息内容", action: action)
    }
}


// MARK: - 测试兼容块类型

/// 本地轻量块枚举：仅用于测试兼容（ChatSessionTests 直接断言该类型）。
/// 渲染层统一由 MinisCore.MarkdownBlock 驱动（见 MarkdownTextView）。
enum MarkdownBlock: Equatable {
    case code(language: String?, code: String)
    case heading(level: Int, text: String)
    case list(items: [String])
    case paragraph(String)
}

/// 块级解析：委托 MinisCore 容错解析器（流式安全、永不抛错），
/// 再映射为测试兼容的本地块。渲染层直接消费 MinisCore.MarkdownBlock。
enum MarkdownParser {
    static func blocks(from text: String) -> [MarkdownBlock] {
        MinisCore.MarkdownParser.parse(text).map { block in
            switch block {
            case .heading(let level, let text):
                return .heading(level: level, text: text)
            case .paragraph(let s):
                return .paragraph(s)
            case .codeBlock(let language, let code):
                return .code(language: language, code: code)
            case .list(let items, _):
                return .list(items: items)
            case .blockquote(let s):
                return .paragraph(s)
            case .table(let header, let rows):
                let lines = [header.joined(separator: " | ")] + rows.map { $0.joined(separator: " | ") }
                return .paragraph(lines.joined(separator: "\n"))
            case .divider:
                return .paragraph("—")
            }
        }
    }
}

// MARK: - 行内 Markdown（AttributedString 渲染：粗体/斜体/行内代码/链接）

/// 行内 Markdown 文本：**粗体**、*斜体*、`行内代码`、[链接](url)。
/// 流式友好：解析失败（如未闭合标记）时原样回退为纯文本，不吞内容。
struct InlineMarkdownText: View {
    let text: String
    var baseSize: CGFloat = 13

    @Environment(\.themeTokens) private var theme

    var body: some View {
        // Keep the streaming path read-only as well: links are shown as labels,
        // never retained as executable AttributedString link attributes.
        Text(attributed)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var attr: AttributedString
        if let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attr = parsed
        } else {
            attr = AttributedString(text)
        }
        // 行内代码：等宽字体 + 底色；链接：系统蓝
        for run in attr.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].font = .system(size: baseSize - 1, design: .monospaced)
                attr[run.range].backgroundColor = Color(nsColor: .quaternaryLabelColor).opacity(0.3)
                attr[run.range].foregroundColor = Color(nsColor: .systemOrange)
            }
            if run.link != nil {
                attr[run.range].foregroundColor = theme?.aj38.accent.swiftUIColor ?? Color.accentColor
                // A transcript is a display/copy surface. It must not turn assistant
                // text into a navigation or command execution surface.
                attr[run.range].link = nil
            }
        }
        if attr.runs.isEmpty {
            attr = AttributedString(text)
        }
        return attr
    }
}

// MARK: - 代码块

/// 围栏代码块：等宽字体 + 深色背景 + 语言标签 + 复制按钮 + 横向滚动。
struct CodeBlockView: View {
    let language: String?
    let code: String
    var baseSize: CGFloat = 13

    @State private var copied = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：语言标签 + 复制
            HStack(spacing: 8) {
                if let language, !language.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 6, height: 6)
                        Text(language)
                            .font(.system(size: max(9, baseSize - 3), weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    copyTextToClipboard(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label {
                        Text(copied ? "已复制" : "复制")
                    } icon: {
                        MinisIconView(copied ? .check : .copy, state: copied ? .success : .normal, size: 12)
                            .accessibilityHidden(true)
                    }
                        .font(.system(size: 10))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? (theme?.statusSuccess ?? Color.green) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
                .opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: max(9, baseSize - 1), design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(Color(nsColor: .textColor))
                    .padding(.horizontal, 10)
                    .padding(.vertical, ChatReadingLayout.codeVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .quaternaryLabelColor).opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - 引用块

/// 引用块：左侧强调条 + 弱化背景。
struct BlockquoteView: View {
    let text: String
    var baseSize: CGFloat = 13

    var body: some View {
        InlineMarkdownText(text: text, baseSize: baseSize)
            .foregroundStyle(.secondary)
            .padding(.vertical, ChatReadingLayout.blockquoteVerticalPadding)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .padding(.leading, 0)
            }
    }
}

// MARK: - 列表

/// 列表：无序（•）或有序（1. 2. …），行内样式逐项生效。
struct MarkdownListView: View {
    let items: [String]
    let ordered: Bool
    var baseSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: ChatReadingLayout.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: ChatReadingLayout.listMarkerSpacing) {
                    Text(marker(for: index))
                        .font(.system(size: max(10, baseSize - 1), weight: .semibold, design: ordered ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .frame(width: ordered ? 26 : 12, alignment: .trailing)
                    InlineMarkdownText(text: item, baseSize: baseSize)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func marker(for index: Int) -> String {
        ordered ? "\(index + 1)." : "•"
    }
}

// MARK: - 表格

/// 表格：Grid 布局，表头加粗 + 底部分隔线，单元格支持行内样式。
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    var baseSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: ChatReadingLayout.tableRowSpacing) {
            HStack(spacing: ChatReadingLayout.tableColumnSpacing) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    InlineMarkdownText(text: cell, baseSize: baseSize)
                        .font(.system(size: baseSize, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                    .frame(height: 1)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: ChatReadingLayout.tableColumnSpacing) {
                    let cells = padded(row)
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        InlineMarkdownText(text: cell, baseSize: baseSize)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ChatReadingLayout.tablePadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .quaternaryLabelColor).opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 行单元格数不足时补齐，保证与表头列数一致。
    private func padded(_ row: [String]) -> [String] {
        guard row.count < header.count else { return row }
        return row + Array(repeating: "", count: header.count - row.count)
    }
}

// MARK: - 分隔线

/// 分隔线：细横线，深浅色背景下均可见。
struct MarkdownDividerView: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - 单块渲染

/// 由 MinisCore.MarkdownBlock 驱动的单块渲染（流式增量：每帧重新 parse 整个文本，
/// 解析器为纯函数且容错，截断输入不会崩溃，渲染层只负责把块画出来）。
struct MarkdownBlockView: View {
    let block: MinisCore.MarkdownBlock
    var baseSize: CGFloat = 13

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text: text, baseSize: headingSize(level))
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .padding(.top, ChatReadingLayout.headingTopSpacing(level: level))
                .padding(.bottom, ChatReadingLayout.headingBottomSpacing)
        case .paragraph(let t):
            InlineMarkdownText(text: t, baseSize: baseSize)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code, baseSize: baseSize)
        case .blockquote(let t):
            BlockquoteView(text: t, baseSize: baseSize)
        case .list(let items, let ordered):
            MarkdownListView(items: items, ordered: ordered, baseSize: baseSize)
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows, baseSize: baseSize)
        case .divider:
            MarkdownDividerView()
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 7
        case 2: return baseSize + 4
        case 3: return baseSize + 2
        case 4: return baseSize + 1
        case 5: return baseSize
        default: return max(10, baseSize - 1)
        }
    }
}

// MARK: - 完整消息体

/// 消息正文：块级 Markdown 渲染（标题/段落/代码块/引用/列表/表格/分隔线）。
/// 解析由 MinisCore 容错解析器完成，流式输出时随文本增量重渲染。
///
/// F23（Q8-r4 P2-5）：body 每渲染帧都会重算，打字机 3 字符/16ms 逐 tick 触发——
/// 经 MarkdownRenderCache 复用同一文本的 parse 结果，文本不变零重解析。
/// F23（Q8-r4 P2-4）：流式表格定型前后块类型翻转（paragraph→table）属正确语义，
/// ForEach 改用内容稳定 id，翻转只重建受影响块、不牵连全列表。
struct MarkdownTextView: View {
    let text: String
    var baseSize: CGFloat = 13
    @State private var cache = MarkdownRenderCache()

    var body: some View {
        let blocks = cache.blocks(for: text)
        let renderState = cache.renderState(for: text, baseSize: baseSize)

        Group {
            if renderState.isFallback {
                // The same safe attributed state is used for malformed streaming
                // text and the final transcript, so a reopen cannot change meaning.
                ReadOnlyAttributedTextView(attributedString: renderState.attributedString)
                    .frame(maxWidth: ChatReadingLayout.maxContentWidth, alignment: .leading)
                    .accessibilityLabel("只读消息内容")
                    .accessibilityValue(renderState.statusMessage ?? "")
                    .accessibilityIdentifier("markdown.render.fallback")
            } else {
                VStack(alignment: .leading, spacing: ChatReadingLayout.blockSpacing) {
                    ForEach(MarkdownRenderCache.indexed(blocks), id: \.renderID) { entry in
                        MarkdownBlockView(block: entry.block, baseSize: baseSize)
                    }
                }
                .frame(maxWidth: ChatReadingLayout.maxContentWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ChatReadingLayout.horizontalInset)
    }
}

// MARK: - F23 流式渲染缓存

/// F23（Q8-r4 P2-5）：Markdown 渲染缓存。
///
/// SwiftUI body 可能因任意状态变化多次重算；流式打字机场景下 text 逐 tick 变化，
/// 但同一 text 的 body 也可能重算多次。缓存「最近一次 text → blocks」，
/// text 未变直接复用（零 parse），text 变化才重新解析。
///
/// class 引用语义：@State 持有实例跨 body 重算存活；blocks(for:) 只改内部存储，
/// 不改 @State 本身，不触发视图更新循环。
final class MarkdownRenderCache {
    /// 累计 parse 次数（测试可观察）。
    private(set) var parseCount = 0
    private var cachedText: String?
    private var cachedBlocks: [MinisCore.MarkdownBlock] = []
    /// 累计富文本状态构建次数（测试可观察）。
    private(set) var renderStateBuildCount = 0
    private var cachedRenderStateText: String?
    private var cachedRenderStateBaseSize: CGFloat?
    private var cachedRenderState: ReadOnlyAttributedTextRenderState?

    func blocks(for text: String) -> [MinisCore.MarkdownBlock] {
        if let cached = cachedText, cached == text {
            return cachedBlocks
        }
        parseCount += 1
        let parsed = MinisCore.MarkdownParser.parse(text)
        cachedText = text
        cachedBlocks = parsed
        return parsed
    }

    /// Reuse the complete render state when SwiftUI recomputes the same body.
    /// MarkdownTextView's production path always uses `.textColor`; the base
    /// size remains part of the key so a dynamic-type change cannot reuse stale
    /// typography.
    func renderState(
        for text: String,
        baseSize: CGFloat
    ) -> ReadOnlyAttributedTextRenderState {
        if cachedRenderStateText == text,
           cachedRenderStateBaseSize == baseSize,
           let cachedRenderState {
            return cachedRenderState
        }

        renderStateBuildCount += 1
        let rendered = MarkdownAttributedTextBuilder.renderState(
            content: text,
            isMarkdown: true,
            baseSize: baseSize,
            baseColor: .textColor
        )
        cachedRenderStateText = text
        cachedRenderStateBaseSize = baseSize
        cachedRenderState = rendered
        return rendered
    }

    /// F23（Q8-r4 P2-4）：内容稳定 id —— offset + 块内容 hash 组合。
    /// 块类型翻转（如流式表格定型 paragraph→table）时，未变块 id 不变，
    /// SwiftUI 差量更新只重建受影响区域。
    struct IndexedBlock {
        let renderID: String
        let block: MinisCore.MarkdownBlock
    }

    static func indexed(_ blocks: [MinisCore.MarkdownBlock]) -> [IndexedBlock] {
        blocks.enumerated().map { offset, block in
            // Swift's Hasher is intentionally seeded per process, so hashValue can
            // change after reopening the app and needlessly rebuild every block.
            // FNV-1a over the value description is small, deterministic, and does
            // not include any external metadata.
            IndexedBlock(renderID: "\(offset):\(stableDigest(block))", block: block)
        }
    }

    private static func stableDigest(_ block: MinisCore.MarkdownBlock) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in String(describing: block).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
