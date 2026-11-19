//
//  MarkdownParser.swift
//  MinisCore
//
//  纯 Swift 容错 Markdown 解析器（无 cmark 依赖）。
//  输入 markdown 字符串 → [MarkdownBlock]，供聊天区流式渲染。
//
//  流式友好设计：解析器是纯函数、永不抛错（parse 无 throws）。
//  面对"半个 markdown"（截断的代码围栏/表格/列表/行内标记）时
//  产出已解析部分：未闭合围栏→整段 codeBlock，未闭合表格→已解析行，
//  未闭合行内标记→原样保留文本。渲染层拿到的是确定、可增量刷新的块数组。
//
//  支持：1~6 级标题、``` 代码块（带语言）、> 引用、-/* 与 1. 列表、
//  | 表格、--- 分隔线。行内样式（**粗体**、*斜体*、`code`）保留原始
//  标记在 block 文本中，由渲染层处理（简单方案）。
//

import Foundation

/// 容错 Markdown 块级解析器。
public struct MarkdownParser: Sendable {

    public init() {}

    /// 解析完整或部分 markdown，返回块数组。输入任意（含空串/截断）均不抛错。
    public func parse(_ markdown: String) -> [MarkdownBlock] {
        guard !markdown.isEmpty else { return [] }

        var blocks: [MarkdownBlock] = []
        let lines = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // 1) 围栏代码块（``` 或 ~~~，3+ 个）
            if let fence = fenceInfo(of: trimmed) {
                let (code, next) = collectCodeBlock(lines: lines, from: i + 1, fenceChar: fence.char, fenceLen: fence.len)
                blocks.append(.codeBlock(language: fence.language, code: code))
                i = next
                continue
            }

            // 2) 标题 # ~ ######
            if let (level, text) = headingInfo(of: trimmed) {
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // 3) 分隔线 --- / *** / ___
            if isDivider(trimmed) {
                blocks.append(.divider)
                i += 1
                continue
            }

            // 4) 引用块（连续 > 行合并）
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        quoted.append(String(rest))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(quoted.joined(separator: "\n")))
                continue
            }

            // 5) 列表（- / * / + 或 1. 开头；按缩进分级，空行不打断同一列表）
            if listMarker(of: trimmed) != nil {
                blocks.append(collectList(lines: lines, from: &i))
                continue
            }

            // 6) 表格：当前行含 | 且下一行是分隔行（|---|）
            if containsPipe(trimmed), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let header = splitTableRow(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !containsPipe(t) { break }
                    rows.append(splitTableRow(t))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 7) 段落：收集连续非空且非块起始的行
            var para: [String] = [raw]
            i += 1
            while i < lines.count {
                let t = lines[i]
                let tt = t.trimmingCharacters(in: .whitespaces)
                if tt.isEmpty || isBlockStart(tt) { break }
                para.append(t)
                i += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }

        return blocks
    }

    /// 静态便捷入口。
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownParser().parse(markdown)
    }

    // MARK: - 列表

    private func indentWidth(of line: String) -> Int {
        var w = 0
        for ch in line {
            if ch == " " { w += 1 } else if ch == "\t" { w += 4 } else { break }
        }
        return w
    }

    /// 从 lines[i] 起收集一个完整列表（支持嵌套、有序起始序号、项间空行），推进 i。
    private func collectList(lines: [String], from i: inout Int) -> MarkdownBlock {
        var items: [MarkdownListItem] = []
        var indentStack: [Int] = []
        var counters: [Int: Int] = [:] // level -> 下一个序号

        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                // 空行：仅当后面（跳过空行）紧跟列表项时才继续同一列表
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, listMarker(of: lines[j].trimmingCharacters(in: .whitespaces)) != nil {
                    i = j
                    continue
                }
                break
            }
            if let (len, ordered) = listMarker(of: t) {
                let indent = indentWidth(of: raw)
                while let last = indentStack.last, last > indent { indentStack.removeLast() }
                if indentStack.last != indent { indentStack.append(indent) }
                let level = indentStack.count - 1
                for key in Array(counters.keys) where key > level { counters[key] = nil }
                var number = 0
                if ordered {
                    if let next = counters[level] {
                        number = next
                    } else {
                        number = Int(t.prefix(while: { $0.isNumber })) ?? 1
                    }
                    counters[level] = number + 1
                }
                let text = String(t.dropFirst(len)).trimmingCharacters(in: .whitespaces)
                items.append(MarkdownListItem(level: level, ordered: ordered, number: number, text: text))
                i += 1
            } else if !items.isEmpty, indentWidth(of: raw) >= 2, !isBlockStart(t) {
                // 缩进的续行并入上一项
                let last = items.removeLast()
                items.append(MarkdownListItem(level: last.level, ordered: last.ordered, number: last.number,
                                              text: last.text + "\n" + t))
                i += 1
            } else {
                break
            }
        }

        let simple = !items.isEmpty
            && items.allSatisfy { $0.level == 0 && $0.ordered == items[0].ordered }
            && (!items[0].ordered || items[0].number == 1)
        if simple {
            return .list(items: items.map(\.text), ordered: items[0].ordered)
        }
        return .nestedList(items: items)
    }

    // MARK: - 行级识别

    private struct Fence {
        let char: Character
        let len: Int
        let language: String?
    }

    private func fenceInfo(of trimmed: String) -> Fence? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var len = 0
        for ch in trimmed {
            if ch == first { len += 1 } else { break }
        }
        guard len >= 3 else { return nil }
        let rest = trimmed.dropFirst(len).trimmingCharacters(in: .whitespaces)
        return Fence(char: first, len: len, language: rest.isEmpty ? nil : rest)
    }

    /// 从 fence 下一行开始收集代码，直到闭合围栏或输入结束（容错：未闭合也返回）。
    /// 返回 (code, 下一个待处理行下标)。
    private func collectCodeBlock(lines: [String], from start: Int, fenceChar: Character, fenceLen: Int) -> (String, Int) {
        var code: [String] = []
        var i = start
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = t.first, f == fenceChar, fenceCloseLength(of: t, char: fenceChar) >= fenceLen {
                i += 1
                break
            }
            code.append(lines[i])
            i += 1
        }
        return (code.joined(separator: "\n"), i)
    }

    private func fenceCloseLength(of trimmed: String, char: Character) -> Int {
        // Q8-r4 P1-1 修复：闭合围栏 = 行首前缀连续的围栏字符 + 仅允许尾部空白
        // （CommonMark：闭合围栏不含 info string）。原实现统计全行任意位置
        // 的围栏字符数，行内反引号（如 `a`b`）会被误判为闭合，代码块内容泄漏。
        var len = 0
        for ch in trimmed {
            if ch == char { len += 1 } else { break }
        }
        let rest = trimmed.dropFirst(len)
        guard rest.allSatisfy({ $0 == " " || $0 == "\t" }) else { return 0 }
        return len
    }

    private func headingInfo(of trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6, level < trimmed.count else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil } // `#text` 不是标题
        return (level, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private func isDivider(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// 识别列表标记，返回 (标记长度, 是否有序)。`-`、`- `、`1.`、`1. x` 均识别。
    private func listMarker(of trimmed: String) -> (len: Int, ordered: Bool)? {
        guard let first = trimmed.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            if trimmed.count == 1 { return (1, false) } // 流式中间态：只有标记
            let second = trimmed[trimmed.index(after: trimmed.startIndex)]
            if second == " " || second == "\t" { return (1, false) }
            return nil
        }
        // 有序：数字 + "." + 空白
        var digits = 0
        for ch in trimmed {
            if ch.isNumber { digits += 1 } else { break }
        }
        guard digits > 0 else { return nil }
        let afterDigits = trimmed.dropFirst(digits)
        guard afterDigits.first == "." else { return nil }
        let rest = afterDigits.dropFirst()
        if rest.isEmpty { return (digits + 1, true) }
        if rest.first == " " || rest.first == "\t" { return (digits + 1, true) }
        return nil
    }

    private func containsPipe(_ s: String) -> Bool {
        s.contains("|")
    }

    /// 分隔行：如 `|---|---|`、`|:--|--:|`。每个单元格只含 - : 与空白，且至少一个 -。
    private func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            guard c.allSatisfy({ $0 == "-" || $0 == ":" }) else { return false }
        }
        return true
    }

    /// 拆表格行：去掉首尾 |，按 | 拆分，单元格去空白。
    private func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// 段落收集时遇到的块起始行。
    private func isBlockStart(_ trimmed: String) -> Bool {
        if fenceInfo(of: trimmed) != nil { return true }
        if headingInfo(of: trimmed) != nil { return true }
        if isDivider(trimmed) { return true }
        if trimmed.hasPrefix(">") { return true }
        if listMarker(of: trimmed) != nil { return true }
        return false
    }
}
