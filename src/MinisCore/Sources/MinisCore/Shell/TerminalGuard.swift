import Foundation

/// Result of parsing a command before it reaches a shell process.
public struct TerminalGuardResult: Equatable, Sendable {
    public let isAllowed: Bool
    public let rejectionReason: String?
    public let words: [String]

    fileprivate init(isAllowed: Bool, rejectionReason: String?, words: [String] = []) {
        self.isAllowed = isAllowed
        self.rejectionReason = rejectionReason
        self.words = words
    }
}

/// Conservative shell syntax guard for `shell_execute`.
///
/// The guard lexes shell words and operators instead of searching for blocked
/// substrings. Operators inside quotes or escaped operators remain ordinary
/// arguments. A command is allowed only when it is one simple command with no
/// shell expansion, redirection, backgrounding, or command-dispatch wrapper.
/// Approval remains a separate policy concern; this type only rejects syntax
/// that cannot be safely represented as one command execution.
public enum TerminalGuard {
    private enum QuoteMode {
        case none
        case single
        case double
    }

    private static let shellExecutables: Set<String> = [
        "bash", "dash", "fish", "ksh", "sh", "zsh",
    ]

    private static let wrapperExecutables: Set<String> = [
        "command", "exec", "nice", "sudo",
    ]

    /// Parse and validate a command without spawning a process.
    public static func inspect(_ command: String) -> TerminalGuardResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return reject("command is empty")
        }

        // The lexer walks `Character`s, and Swift folds "\r\n" into ONE
        // Character that is neither "\n" nor a plain space, and folds any
        // ASCII operator followed by a combining mark into a different
        // Character. A shell sees the raw bytes, so reject these before lexing.
        if let rejection = unsafeScalarRejection(trimmed) {
            return reject(rejection)
        }

        let lexed = lex(trimmed)
        if let rejection = lexed.rejection {
            return TerminalGuardResult(isAllowed: false, rejectionReason: rejection, words: lexed.words)
        }
        guard !lexed.words.isEmpty else {
            return reject("command contains no executable")
        }

        if let rejection = validateExecutable(lexed.words) {
            return TerminalGuardResult(isAllowed: false, rejectionReason: rejection, words: lexed.words)
        }
        return TerminalGuardResult(isAllowed: true, rejectionReason: nil, words: lexed.words)
    }

    /// Scalar-level pre-scan (not Character-level). "\n" and "\t" keep their
    /// existing handling in the lexer; everything else that a shell or a human
    /// could read as a line break or hidden separator is rejected outright.
    private static func unsafeScalarRejection(_ command: String) -> String? {
        var previous: Unicode.Scalar?
        for scalar in command.unicodeScalars {
            defer { previous = scalar }
            if scalar == "\n" || scalar == "\t" { continue }
            switch scalar.properties.generalCategory {
            case .control:
                return "control character U+\(hex(scalar)) is not allowed"
            case .lineSeparator, .paragraphSeparator:
                return "Unicode line separator U+\(hex(scalar)) is not allowed"
            case .nonspacingMark, .spacingMark, .enclosingMark:
                if let previous, previous.isASCII,
                   !(previous.properties.isAlphabetic || previous.properties.numericType != nil) {
                    return "combining mark after ASCII punctuation or whitespace is not allowed"
                }
            default:
                break
            }
        }
        return nil
    }

    private static func hex(_ scalar: Unicode.Scalar) -> String {
        let digits = String(scalar.value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    private static func reject(_ reason: String) -> TerminalGuardResult {
        TerminalGuardResult(isAllowed: false, rejectionReason: reason)
    }

    /// Lex only the shell syntax relevant to safety. This intentionally does
    /// not attempt to implement shell execution semantics; it stops at the
    /// first construct that would create a second command or another parser.
    private static func lex(_ command: String) -> (words: [String], rejection: String?) {
        let chars = Array(command)
        var words: [String] = []
        var current = ""
        var tokenStarted = false
        var mode: QuoteMode = .none
        var index = 0

        func finishWord() {
            if tokenStarted {
                words.append(current)
                current.removeAll(keepingCapacity: true)
                tokenStarted = false
            }
        }

        while index < chars.count {
            let character = chars[index]

            switch mode {
            case .single:
                if character == "'" {
                    mode = .none
                } else {
                    current.append(character)
                }
                index += 1
                continue

            case .double:
                if character == "\"" {
                    mode = .none
                    index += 1
                    continue
                }
                if character == "\\" {
                    guard index + 1 < chars.count else {
                        return (words, "unterminated escape")
                    }
                    let next = chars[index + 1]
                    if next == "\n" {
                        index += 2
                    } else {
                        current.append(next)
                        index += 2
                    }
                    tokenStarted = true
                    continue
                }
                if character == "`" {
                    return (words, "command substitution with backticks is not allowed")
                }
                if character == "$", index + 1 < chars.count, chars[index + 1] == "(" {
                    return (words, "command substitution with $() is not allowed")
                }
                if character == "$", let reason = parameterExpansionReason(at: index, chars: chars) {
                    return (words, reason)
                }
                current.append(character)
                tokenStarted = true
                index += 1
                continue

            case .none:
                break
            }

            if character == "'" {
                mode = .single
                tokenStarted = true
                index += 1
                continue
            }
            if character == "\"" {
                mode = .double
                tokenStarted = true
                index += 1
                continue
            }
            if character == "\\" {
                guard index + 1 < chars.count else {
                    return (words, "unterminated escape")
                }
                let next = chars[index + 1]
                if next != "\n" {
                    current.append(next)
                    tokenStarted = true
                }
                index += 2
                continue
            }
            if character == "`" {
                return (words, "command substitution with backticks is not allowed")
            }
            if character == "$", index + 1 < chars.count, chars[index + 1] == "(" {
                return (words, "command substitution with $() is not allowed")
            }
            if character == "$", let reason = parameterExpansionReason(at: index, chars: chars) {
                return (words, reason)
            }
            if character == "#", !tokenStarted {
                // A comment does not make the following newline safe; the
                // newline is still processed as a command separator below.
                while index < chars.count, chars[index] != "\n" {
                    index += 1
                }
                continue
            }
            if let operatorReason = operatorReason(at: index, chars: chars) {
                finishWord()
                return (words, operatorReason)
            }

            if character.isWhitespace {
                finishWord()
                index += 1
                continue
            }

            current.append(character)
            tokenStarted = true
            index += 1
        }

        if mode != .none {
            return (words, "unterminated quote")
        }
        finishWord()
        return (words, nil)
    }

    private static func operatorReason(at index: Int, chars: [Character]) -> String? {
        let character = chars[index]
        switch character {
        case ";":
            return "command separator ';' is not allowed"
        case "&":
            return index + 1 < chars.count && chars[index + 1] == "&"
                ? "conditional operator '&&' is not allowed"
                : "background operator '&' is not allowed"
        case "|":
            return index + 1 < chars.count && chars[index + 1] == "|"
                ? "conditional operator '||' is not allowed"
                : "pipeline operator '|' is not allowed"
        case ">", "<":
            return "redirection operator is not allowed"
        case "\n":
            return "newline command separator is not allowed"
        case "(", ")", "{", "}":
            return "command grouping is not allowed"
        default:
            return nil
        }
    }

    private static func parameterExpansionReason(at index: Int, chars: [Character]) -> String? {
        guard index + 1 < chars.count else { return nil }
        let next = chars[index + 1]
        if next == "{" || next == "$" || next == "@" || next == "*" || next == "?" || next == "!" || next == "#" {
            return "parameter expansion is not allowed"
        }
        if next.isLetter || next.isNumber || next == "_" {
            return "parameter expansion is not allowed"
        }
        return nil
    }

    /// A denied or approval-required shell command must not acquire a second
    /// executable through parameter expansion after classification. Inspect
    /// the original quoting here: `words` have already lost the difference
    /// between `$VAR` and the literal `'$VAR'` / `\$VAR`.
    static func containsActiveDollar(_ command: String) -> Bool {
        let chars = Array(command)
        var mode: QuoteMode = .none
        var tokenStarted = false
        var index = 0
        while index < chars.count {
            let character = chars[index]
            switch mode {
            case .single:
                if character == "'" { mode = .none }
            case .double:
                if character == "\\", index + 1 < chars.count {
                    index += 1
                } else if character == "\"" {
                    mode = .none
                } else if character == "$" {
                    return true
                }
            case .none:
                if character == "\\", index + 1 < chars.count {
                    index += 1
                    tokenStarted = true
                } else if character == "'" {
                    mode = .single
                    tokenStarted = true
                } else if character == "\"" {
                    mode = .double
                    tokenStarted = true
                } else if character == "#", !tokenStarted {
                    while index < chars.count, chars[index] != "\n" { index += 1 }
                    tokenStarted = false
                    continue
                } else if character == "$" {
                    return true
                } else if character.isWhitespace {
                    tokenStarted = false
                } else {
                    tokenStarted = true
                }
            }
            index += 1
        }
        return false
    }

    /// Resolve command-dispatch wrappers structurally, then reject a shell
    /// interpreter or xargs as the actual executable. This catches `env bash
    /// -c ...` without treating an arbitrary argument containing "bash" as
    /// dangerous text. Options which introduce another command parser are
    /// rejected before their quoted payload can be mistaken for an argument.
    private struct ExecutableResolution {
        let executable: String?
        let rejection: String?

        static func accepted(_ executable: String) -> Self {
            Self(executable: executable, rejection: nil)
        }

        static func rejected(_ reason: String) -> Self {
            Self(executable: nil, rejection: reason)
        }
    }

    private static func validateExecutable(_ words: [String]) -> String? {
        resolveCommand(words, from: 0).rejection
    }

    /// The same wrapper grammar used by `inspect` supplies the executable
    /// that the policy must classify. `env open` and `nice sudo` cannot inherit
    /// the wrapper's allow-list category; quoted ordinary arguments remain
    /// arguments rather than extra executables.
    static func effectiveExecutable(in words: [String]) -> String? {
        let resolution = resolveCommand(words, from: 0)
        return resolution.rejection == nil ? resolution.executable : nil
    }

    private static func resolveCommand(_ words: [String], from start: Int) -> ExecutableResolution {
        var index = start
        while index < words.count {
            while index < words.count, isEnvironmentAssignment(words[index]) {
                index += 1
            }
            guard index < words.count else {
                return .rejected("command contains no executable")
            }
            let executable = basename(words[index])
            if executable == "env" {
                return resolveEnv(words, from: index)
            }
            if executable == "nice" {
                guard let commandIndex = nextNiceCommandIndex(words, from: index) else {
                    return .rejected("nice wrapper has an unsupported or missing option value")
                }
                return resolveCommand(words, from: commandIndex)
            }
            if wrapperExecutables.contains(executable) {
                // These wrappers can change the parser, privilege, or process
                // image. There is no safe reason for shell_execute to invoke
                // them, so do not try to infer their option grammar.
                return .rejected("command wrapper '\(executable)' is not allowed")
            }

            if shellExecutables.contains(executable) {
                return .rejected("shell interpreter '\(executable)' is not allowed")
            }
            if executable == "xargs" {
                return .rejected("xargs command dispatch is not allowed")
            }
            return .accepted(executable)
        }
        return .rejected("command contains no executable")
    }

    private static func resolveEnv(_ words: [String], from envIndex: Int) -> ExecutableResolution {
        var index = envIndex + 1
        while index < words.count {
            let word = words[index]
            if isEnvironmentAssignment(word) {
                index += 1
                continue
            }
            if word == "--" {
                index += 1
                break
            }
            if word == "-S" || word == "--split-string" || word.hasPrefix("--split-string=") {
                return .rejected("env split-string command dispatch is not allowed")
            }
            if word == "-u" || word == "--unset" || word == "-C" || word == "--chdir" {
                guard index + 1 < words.count else {
                    return .rejected("env option '\(word)' is missing its operand")
                }
                index += 2
                continue
            }
            if word.hasPrefix("-u"), word.count > 2 {
                index += 1
                continue
            }
            if word.hasPrefix("--unset=") || word.hasPrefix("--chdir=") {
                index += 1
                continue
            }
            if word == "-i" || word == "--ignore-environment" || word == "-0" || word == "--null" {
                index += 1
                continue
            }
            if word.hasPrefix("-") {
                return .rejected("unsupported env option '\(word)'")
            }
            break
        }

        // `env` without a command only prints the environment and is safe to
        // represent as one process. If a command follows, validate that
        // command recursively so `env nice ... bash -c ...` cannot bypass.
        guard index < words.count else { return .accepted("env") }
        return resolveCommand(words, from: index)
    }

    private static func nextNiceCommandIndex(_ words: [String], from niceIndex: Int) -> Int? {
        var index = niceIndex + 1
        while index < words.count {
            let word = words[index]
            if word == "--" {
                index += 1
                break
            }
            guard word.hasPrefix("-") else { break }
            if word == "-n" || word == "--adjustment" {
                guard index + 1 < words.count else { return nil }
                index += 2
                continue
            }
            if word.hasPrefix("--adjustment=") ||
                (word.hasPrefix("-n") && word.count > 2) ||
                (word.count > 1 && word.dropFirst().allSatisfy(\.isNumber)) {
                index += 1
                continue
            }
            return nil
        }
        guard index < words.count else { return nil }
        return index
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func basename(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }
}
