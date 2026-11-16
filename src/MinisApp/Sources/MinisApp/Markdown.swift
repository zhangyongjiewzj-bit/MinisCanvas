import SwiftUI

// MARK: - 轻量 Markdown 渲染（粗体 / 斜体 / 行内代码 / 代码块 / 列表）

enum MarkdownBlock {
    case paragraph(String)
    case heading(String)
    case listItem(String)
    case code(String)
}

enum MarkdownRenderer {

    /// 按行分组为块：``` 围栏代码块、# 标题、-/*/数字 列表项、其余段落。
    static func blocks(from text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var codeLines: [String] = []
        var inCode = false

        func flushCode() {
            if !codeLines.isEmpty {
                result.append(.code(codeLines.joined(separator: "\n")))
                codeLines = []
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    inCode = false
                } else {
                    flushCode()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("#") {
                flushCode()
                result.append(.heading(String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushCode()
                result.append(.listItem(String(trimmed.dropFirst(2))))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed.prefix(upTo: dot).allSatisfy({ $0.isNumber }) {
                flushCode()
                result.append(.listItem(String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            result.append(.paragraph(line))
        }
        flushCode()
        return result
    }

    /// 行内渲染：`**bold**`、`*italic*`、`` `code` `` → Text 拼接。
    static func inline(_ markdown: String) -> Text {
        var output = Text("")
        let pattern = #"(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(markdown)
        }
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var last = 0
        for m in matches {
            let r = m.range
            if r.location > last {
                output = output + Text(ns.substring(with: NSRange(location: last, length: r.location - last)))
            }
            let token = ns.substring(with: r)
            if token.hasPrefix("**") {
                output = output + Text(String(token.dropFirst(2).dropLast(2))).bold()
            } else if token.hasPrefix("`") {
                output = output + Text(String(token.dropFirst().dropLast())).monospaced().foregroundColor(.orange)
            } else {
                output = output + Text(String(token.dropFirst().dropLast())).italic()
            }
            last = r.location + r.length
        }
        if last < ns.length {
            output = output + Text(ns.substring(from: last))
        }
        return output
    }
}
