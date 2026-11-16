// Historical source: OpenMinis BashismDetector shell-portability checks.
// Reimplemented from an independent behavior specification.
import Foundation

public enum BashismDetector {
    public struct BashismWarning: Sendable, Equatable {
        public let line: Int
        public let ruleName: String
        public let matchedText: String
        public let message: String
        public let fixHint: String
    }

    public static func detect(_ script: String) -> [BashismWarning] {
        var warnings: [BashismWarning] = []
        for row in shellLayerLines(script) {
            guard let raw = row.text else { continue }
            let text = String(raw.prefix(4096)).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasPrefix("#") { continue }
            let checks: [(String, Bool, String)] = [
                ("doubleBracketTest", text.contains("[["), "Use the POSIX [ test command."),
                ("regexMatchOperator", text.contains("=~"), "Use case patterns or an explicit grep invocation."),
                ("bothStreamRedirect", hasCombinedRedirect(text), "Redirect stdout, then use 2>&1."),
                ("nestedCommandSubstitution", hasNestedSubstitution(text), "Assign the inner command result before the outer command."),
                ("functionKeyword", text.hasPrefix("function ") || text.hasPrefix("function\t"), "Declare functions as name() { ...; }."),
                ("hereString", text.contains("<<<"), "Pass data with printf and a pipe, or use a here-document."),
                ("arithmeticForLoop", hasArithmeticLoop(text), "Use a while test with POSIX arithmetic expansion."),
                ("bashArrayAssignment", hasArrayAssignment(text), "Use positional parameters or separate scalar variables."),
                ("caseModificationExpansion", hasExtendedParameterExpansion(text), "Use tr or sed for case conversion and replacement."),
                ("processSubstitution", text.contains("<(") || text.contains(">("), "Use a pipe or an explicitly managed temporary file.")
            ]
            for (name, hit, hint) in checks where hit {
                warnings.append(BashismWarning(line: row.line, ruleName: name,
                    matchedText: String(text.prefix(160)),
                    message: "This \(name) construct is outside POSIX sh; zsh compatibility does not imply POSIX portability.",
                    fixHint: hint))
            }
        }
        return warnings
    }

    static func shellLayerLines(_ script: String) -> [(line: Int, text: String?)] {
        var waiting: [(delimiter: String, stripTabs: Bool)] = []
        return script.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { offset, raw in
            var text = String(raw)
            if text.last == "\r" { text.removeLast() }
            if let first = waiting.first {
                let candidate = first.stripTabs ? String(text.drop(while: { $0 == "\t" })) : text
                if candidate.trimmingCharacters(in: .whitespacesAndNewlines) == first.delimiter {
                    waiting.removeFirst()
                }
                return (offset + 1, nil)
            }
            waiting.append(contentsOf: heredocDelimiters(String(text.prefix(4096))))
            return (offset + 1, text)
        }
    }

    private static func heredocDelimiters(_ text: String) -> [(delimiter: String, stripTabs: Bool)] {
        let chars = Array(text)
        var result: [(String, Bool)] = []
        var cursor = 0
        var quoted: Character?
        while cursor < chars.count {
            let character = chars[cursor]
            if character == "\\" { cursor += 2; continue }
            if let quote = quoted {
                if character == quote { quoted = nil }
                cursor += 1
                continue
            }
            if character == "'" || character == "\"" { quoted = character; cursor += 1; continue }
            if character == "#", cursor == 0 || chars[cursor - 1].isWhitespace { break }
            guard character == "<", cursor + 1 < chars.count, chars[cursor + 1] == "<" else {
                cursor += 1
                continue
            }
            cursor += 2
            if cursor < chars.count, chars[cursor] == "<" { cursor += 1 }
            let stripTabs = cursor < chars.count && chars[cursor] == "-"
            if stripTabs { cursor += 1 }
            while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }
            guard cursor < chars.count else { break }
            var delimiter = ""
            if chars[cursor] == "'" || chars[cursor] == "\"" {
                let quote = chars[cursor]
                cursor += 1
                while cursor < chars.count, chars[cursor] != quote {
                    delimiter.append(chars[cursor]); cursor += 1
                }
                if cursor < chars.count { cursor += 1 }
            } else {
                while cursor < chars.count, !chars[cursor].isWhitespace,
                      !";|&<>()".contains(chars[cursor]) {
                    delimiter.append(chars[cursor]); cursor += 1
                }
            }
            if !delimiter.isEmpty { result.append((delimiter, stripTabs)) }
        }
        return result
    }

    private static func hasCombinedRedirect(_ text: String) -> Bool {
        text.contains("&>")
    }

    private static func hasNestedSubstitution(_ text: String) -> Bool {
        let chars = Array(text)
        var depth = 0
        var backticks = 0
        for index in chars.indices {
            if chars[index] == "`" { backticks += 1 }
            if chars[index] == "$", index + 1 < chars.count, chars[index + 1] == "(" {
                depth += 1
                if depth > 1 { return true }
            } else if chars[index] == ")" {
                depth = max(0, depth - 1)
            }
        }
        return backticks >= 3
    }

    private static func hasArithmeticLoop(_ text: String) -> Bool {
        for keyword in ["for", "while"] where text.hasPrefix(keyword) {
            let tail = text.dropFirst(keyword.count)
            if (tail.first?.isWhitespace == true || tail.hasPrefix("((")),
               tail.drop(while: { $0.isWhitespace }).hasPrefix("((") { return true }
        }
        return false
    }

    private static func hasArrayAssignment(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        let tail = text.drop(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            .drop(while: { $0.isWhitespace })
        return tail.first == "=" && tail.dropFirst().drop(while: { $0.isWhitespace }).first == "("
    }

    private static func hasExtendedParameterExpansion(_ text: String) -> Bool {
        var tail = text[...]
        while let start = tail.range(of: "${"), let end = tail[start.upperBound...].firstIndex(of: "}") {
            let body = tail[start.upperBound..<end]
            let name = body.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            let operation = body.dropFirst(name.count)
            if !name.isEmpty && (operation.hasPrefix("^") || operation.hasPrefix(",")
                                || operation.hasPrefix("//")) { return true }
            tail = tail[tail.index(after: end)...]
        }
        return false
    }
}
