//
//  MarkdownBlock.swift
//  MinisCore
//
//  Block-level AST 产出模型，供聊天区流式渲染使用。
//  块模型概念参照 OpenMinis Agent/Markdown（BlockNode）；本工程保留最小值模型：
//  纯值类型、Codable（可落盘/传输）、Sendable（跨 actor 安全）。
//  行内样式（**粗体**、*斜体*、`code`）按简单方案处理：
//  block 文本保留原始行内标记，由渲染层负责解析呈现。
//

import Foundation

/// Markdown 顶层块类型。渲染层（MinisCanvasApp 的 MarkdownView）据此逐块渲染。
public enum MarkdownBlock: Equatable, Hashable, Codable, Sendable {
    /// 标题，level 1~6（`#` ~ `######`）
    case heading(level: Int, text: String)
    /// 普通段落，text 保留原始行内标记
    case paragraph(String)
    /// 围栏代码块；language 为围栏后标注（如 `swift`），未标注为 nil
    case codeBlock(language: String?, code: String)
    /// 引用块（`>` 开头），text 为去掉 `>` 前缀后的内容
    case blockquote(String)
    /// 列表；ordered=false 为 `-`/`*` 无序，true 为 `1.` 有序
    case list(items: [String], ordered: Bool)
    /// 带嵌套或非 1 起头序号的列表；每项带层级与序号。简单平铺列表仍用 `.list`。
    case nestedList(items: [MarkdownListItem])
    /// 表格；header 为表头，rows 为数据行（含分隔行后的全部行）
    case table(header: [String], rows: [[String]])
    /// 分隔线（`---` / `***` / `___`）
    case divider
}

/// 嵌套列表中的一项。level 从 0 起；ordered 项的 number 为显示序号。
public struct MarkdownListItem: Equatable, Hashable, Codable, Sendable {
    public let level: Int
    public let ordered: Bool
    public let number: Int
    public let text: String

    public init(level: Int, ordered: Bool, number: Int, text: String) {
        self.level = level
        self.ordered = ordered
        self.number = number
        self.text = text
    }
}
