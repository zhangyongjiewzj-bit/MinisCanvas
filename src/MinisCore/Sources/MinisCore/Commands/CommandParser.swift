import Foundation

public enum CommandParseDisposition: String, Sendable, Equatable {
    case command
    case message
}

/// The parser's typed hand-off state. `disposition` remains source-compatible
/// for callers that only distinguish commands from messages; this value keeps
/// unsupported input and policy-gated commands explicit for the next layer.
public enum CommandIntentDisposition: String, Sendable, Equatable {
    case exactCommand
    case authorizationRequired
    case unsupported
    case message
}

/// A stable command intent, detached from the original prose input.
public struct ExactCommandIntent: Sendable, Equatable {
    public let commandID: String
    public let arguments: [String: String]
    public let requiresAuthorization: Bool

    public init(
        commandID: String,
        arguments: [String: String],
        requiresAuthorization: Bool
    ) {
        self.commandID = CommandDefinition.canonicalID(commandID)
        self.arguments = arguments
        self.requiresAuthorization = requiresAuthorization
    }
}

public enum CommandCompletionKey: Sendable, Equatable {
    case tab
    case up
    case down
    case enter
    case escape
}

public enum CommandCompletionAction: Sendable, Equatable {
    case moveSelection(index: Int)
    case accept(commandID: String)
    case dismiss
    case noop
}

public struct CommandCompletionState: Sendable {
    public let suggestions: [CommandDefinition]
    public private(set) var selectedIndex: Int?
    public private(set) var dismissed: Bool

    public var selected: CommandDefinition? {
        guard let selectedIndex, suggestions.indices.contains(selectedIndex) else {
            return nil
        }
        return suggestions[selectedIndex]
    }

    public init(suggestions: [CommandDefinition], selectedIndex: Int? = nil) {
        self.suggestions = suggestions
        self.selectedIndex = selectedIndex
        self.dismissed = false
    }

    @discardableResult
    public mutating func handle(_ key: CommandCompletionKey) -> CommandCompletionAction {
        guard !dismissed else { return .noop }

        switch key {
        case .up:
            return moveSelection(by: -1)
        case .down:
            return moveSelection(by: 1)
        case .tab, .enter:
            guard let selected else { return .noop }
            return .accept(commandID: selected.id)
        case .escape:
            dismissed = true
            return .dismiss
        }
    }

    private mutating func moveSelection(by offset: Int) -> CommandCompletionAction {
        guard !suggestions.isEmpty else { return .noop }
        let current = selectedIndex ?? 0
        let next = min(max(current + offset, 0), suggestions.count - 1)
        selectedIndex = next
        return .moveSelection(index: next)
    }
}

// MARK: - ParsedCommand

/// 一次解析的结果：要么命中一条命令（`command != nil`），
/// 要么给出建议列表（`suggestions`）。
public struct ParsedCommand: Sendable {
    public let command: CommandDefinition?
    public let args: [String: String]
    public let suggestions: [CommandDefinition]
    public let matchScore: Int
    public let disposition: CommandParseDisposition
    public let intentDisposition: CommandIntentDisposition

    public var matched: Bool { command != nil }

    /// A typed intent suitable for Policy/Approval routing. No raw input is
    /// retained, so later consumers cannot accidentally re-parse prose.
    public var exactIntent: ExactCommandIntent? {
        guard let command else { return nil }
        return ExactCommandIntent(
            commandID: command.id,
            arguments: args,
            requiresAuthorization: command.requiresConfirmation
        )
    }

    public init(
        command: CommandDefinition?,
        args: [String: String] = [:],
        suggestions: [CommandDefinition] = [],
        matchScore: Int = 0,
        disposition: CommandParseDisposition? = nil,
        intentDisposition: CommandIntentDisposition? = nil
    ) {
        self.command = command
        self.args = args
        self.suggestions = suggestions
        self.matchScore = matchScore
        let resolvedDisposition = disposition ?? (command == nil ? .message : .command)
        self.disposition = resolvedDisposition
        self.intentDisposition = intentDisposition ?? {
            guard let command else {
                return resolvedDisposition == .message ? .message : .unsupported
            }
            return command.requiresConfirmation ? .authorizationRequired : .exactCommand
        }()
    }
}

// MARK: - CommandParser

/// 自然语言命令解析器：把用户输入（"设置日志级别为 debug"）匹配到
/// 命令 + 参数。支持三种输入形态：
/// 1. 结构化 id：`env.list`、`/env.list`、`env list`
/// 2. 自然语言关键词匹配（中文/英文关键词 + 别名 + 标题词）
/// 3. 匹配失败 → 返回建议列表
public struct CommandParser: Sendable {

    /// Upper bound for one command submission. This applies before matching or
    /// custom argument parsing, preventing pasted documents from becoming a
    /// command intent by accident.
    public static let maxInputLength = 4_096
    private static let maxTokenCount = 64

    /// 关键词命中得分。
    private static let keywordScore = 12
    /// alias 命中得分。
    private static let aliasScore = 40
    /// id 组成部分（"env"、"list"）命中得分。
    private static let idTokenScore = 20
    /// 标题词命中得分。
    private static let titleWordScore = 5
    /// 判定为「命中」的最低得分。
    private static let matchThreshold = 12

    public init() {}

    // MARK: - 入口

    public func parse(_ input: String, registry: CommandRegistry) -> ParsedCommand {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= Self.maxInputLength else {
            return ParsedCommand(
                command: nil,
                disposition: .message,
                intentDisposition: .unsupported
            )
        }
        guard !text.isEmpty else {
            return ParsedCommand(command: nil, suggestions: registry.allCommands())
        }
        guard !Self.isURLOrCode(text) else {
            return ParsedCommand(command: nil, disposition: .message)
        }
        let lower = text.lowercased()
        if lower == "help" || lower == "?" || lower == "帮助" {
            return ParsedCommand(command: nil, suggestions: registry.allCommands())
        }

        // 1) 结构化 id
        if let structured = parseStructured(text, registry: registry) {
            return structured
        }

        // 2) 自然语言匹配
        return parseNaturalLanguage(text, registry: registry)
    }

    // MARK: - 结构化 id

    private func parseStructured(_ text: String, registry: CommandRegistry) -> ParsedCommand? {
        var body = text
        // Composer vocabulary is slash-only. `registerComposerCommands` puts
        // plain English words ("stop", "model", "compact", …) into the same
        // canonical registry the structured path reads, so a prose sentence
        // whose FIRST token happens to be a Composer ID would otherwise be
        // turned into an action here and bypass the natural-language gate in
        // `parseNaturalLanguage`. COMMAND-07: 普通自然语言不会误触发.
        let hasSlashPrefix = body.hasPrefix("/")
        if hasSlashPrefix { body = String(body.dropFirst()) }
        let tokens = Self.commandTokens(body)
        guard tokens.count <= Self.maxTokenCount else { return nil }
        guard let first = tokens.first else { return nil }

        // An explicit slash can name a registered multiword alias such as
        // `boundary set`. Resolve the complete alias before its shorter
        // `boundary` command, and extract only the remaining argument tokens.
        // Non-slash prose keeps the existing structured/natural-language gate.
        if hasSlashPrefix, tokens.count >= 2 {
            for count in stride(from: tokens.count, through: 2, by: -1) {
                let alias = tokens.prefix(count).joined(separator: " ")
                guard let command = registry.command(id: alias) else { continue }
                let rest = tokens.dropFirst(count).joined(separator: " ")
                return ParsedCommand(command: command,
                    args: extractArgs(from: rest, command: command), matchScore: 100)
            }
        }

        // 单 token：`env.list` 或 alias
        if let command = registry.command(id: first),
           Self.allowsStructured(command, hasSlashPrefix: hasSlashPrefix) {
            // The Composer workflow runner accepts quoted and multiline
            // input values. Rejoining lexer tokens here would replace line
            // breaks before its command-specific parser sees the input.
            let rest: String
            if hasSlashPrefix, command.id == "workflow",
               let commandStart = body.firstIndex(where: { !$0.isWhitespace }),
               let boundary = body[commandStart...].firstIndex(where: { $0.isWhitespace }) {
                rest = String(body[boundary...])
            } else {
                rest = tokens.dropFirst().joined(separator: " ")
            }
            let args = extractArgs(from: rest, command: command)
            return ParsedCommand(command: command, args: args, matchScore: 100)
        }

        // 双 token：`env list`
        if tokens.count >= 2 {
            let joined = "\(first).\(tokens[1])"
            if let command = registry.command(id: joined),
               Self.allowsStructured(command, hasSlashPrefix: hasSlashPrefix) {
                let rest = tokens.dropFirst(2).joined(separator: " ")
                let args = extractArgs(from: rest, command: command)
                return ParsedCommand(command: command, args: args, matchScore: 100)
            }
        }
        return nil
    }

    /// Structured matching without a leading slash stays reserved for the
    /// preset/`env.list`-style command ids (documented input forms above).
    /// A Composer id resolves only when the caller passed an explicit slash,
    /// so the slash menu, the pending-request seam and this parser keep one
    /// fail-closed rule: prose never becomes a Composer action.
    private static func allowsStructured(
        _ command: CommandDefinition,
        hasSlashPrefix: Bool
    ) -> Bool {
        hasSlashPrefix || !CommandRegistry.composerCommandIDs.contains(command.id)
    }

    // MARK: - 自然语言匹配

    private func parseNaturalLanguage(_ text: String, registry: CommandRegistry) -> ParsedCommand {
        typealias ScoredCommand = (command: CommandDefinition, score: Int)
        var scored: [ScoredCommand] = []
        for command in registry.allCommands() {
            // Composer commands are explicit slash/structured commands. This
            // prevents prose, URLs, and source text from becoming actions.
            if CommandRegistry.composerCommandIDs.contains(command.id) {
                continue
            }
            let s = score(command: command, text: text)
            if s > 0 {
                scored.append((command, s))
            }
        }
        scored.sort {
            $0.score == $1.score ? $0.command.id < $1.command.id : $0.score > $1.score
        }

        guard let best = scored.first, best.score >= Self.matchThreshold else {
            // 无命中：top 建议（按得分）→ 兜底走文本检索 → 再兜底全部命令
            let suggestions: [CommandDefinition] = scored.prefix(5).map { $0.command }
            if !suggestions.isEmpty {
                return ParsedCommand(
                    command: nil,
                    suggestions: suggestions,
                    intentDisposition: text.hasPrefix("/") ? .unsupported : nil
                )
            }
            let searched = registry.search(text)
            return ParsedCommand(
                command: nil,
                suggestions: searched.isEmpty ? Array(registry.allCommands().prefix(5)) : searched,
                intentDisposition: text.hasPrefix("/") ? .unsupported : nil
            )
        }

        // 同分并列时用 customParse 预检决胜：能提取出参数的胜出。
        let topScore = best.score
        let tied = scored.filter { $0.score == topScore }
        var winner = best
        if tied.count > 1 {
            let parsed = tied.filter { entry in
                entry.command.customParse?(text) != nil
            }
            if parsed.count == 1, let only = parsed.first {
                winner = only
            }
        }

        let args = extractArgs(from: text, command: winner.command)
        return ParsedCommand(command: winner.command, args: args, matchScore: winner.score)
    }

    // MARK: - Composer completion

    public func completionState(
        for input: String,
        registry: CommandRegistry
    ) -> CommandCompletionState {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= Self.maxInputLength, text.hasPrefix("/") else {
            return CommandCompletionState(suggestions: [])
        }

        let prefix = String(text.dropFirst()).lowercased()
        let suggestions = registry.allCommands().filter { command in
            guard CommandRegistry.composerCommandIDs.contains(command.id) else {
                return false
            }
            guard !prefix.isEmpty else { return true }
            return command.id.lowercased().hasPrefix(prefix)
                || command.title.lowercased().hasPrefix(prefix)
                || command.aliases.contains { $0.lowercased().hasPrefix(prefix) }
        }
        return CommandCompletionState(
            suggestions: suggestions,
            selectedIndex: suggestions.isEmpty ? nil : 0
        )
    }

    /// 命令与输入文本的匹配得分。
    private func score(command: CommandDefinition, text: String) -> Int {
        let lower = text.lowercased()
        var score = 0

        // id 组成部分："env.list" → ["env", "list"]（词边界匹配，
        // 避免 "openai_api_key" 误命中 settings.open 的 token "open"）
        let idTokens = command.id.split(separator: ".").map(String.init)
        for token in idTokens where containsWord(lower, token) {
            score += Self.idTokenScore
        }
        if lower.contains(command.id.lowercased()) {
            score += 60
        }

        for alias in command.aliases where lower.contains(alias.lowercased()) {
            score += Self.aliasScore
        }

        for keyword in command.keywords where lower.contains(keyword.lowercased()) {
            score += Self.keywordScore
        }

        // 标题分词（英文单词 / 中文两字以上片段）
        let titleWords = command.title
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        for word in titleWords where lower.contains(word.lowercased()) {
            score += Self.titleWordScore
        }

        return score
    }

    /// 词边界匹配：`token` 在 `lower` 中作为独立单词出现
    /// （前后都不是字母/数字/下划线）。token 本身只含 [a-zA-Z0-9_]，
    /// 可直接拼进正则。
    private func containsWord(_ lower: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let pattern = "(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: token) + "(?![a-z0-9_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(lower.startIndex..., in: lower)
        return regex.firstMatch(in: lower, options: [], range: range) != nil
    }

    // MARK: - 参数提取

    /// 提取参数：优先自定义解析器，否则走通用规则
    /// （内联 `k=v` token → choices 扫描 → 位置参数）。
    public func extractArgs(from text: String, command: CommandDefinition) -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxInputLength else { return [:] }
        if let custom = command.customParse, let args = custom(trimmed) {
            return args
        }
        return Self.genericExtract(from: trimmed, specs: command.argumentSpecs)
    }

    /// 通用参数提取：
    /// 1. 内联 `key=value` token（值可带引号）
    /// 2. 带 choices 的规格：扫描候选词（大小写不敏感），valueMap 归一化
    /// 3. 剩余规格按声明顺序吃 token；`.rest` 吃整行
    static func genericExtract(from text: String, specs: [CommandArgumentSpec]) -> [String: String] {
        var args: [String: String] = [:]
        var working = text

        // 1) 内联 k=v
        let tokens = commandTokens(text)
        guard tokens.count <= maxTokenCount else { return [:] }
        for token in tokens {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq]).lowercased()
            guard !key.isEmpty else { continue }
            var value = String(token[token.index(after: eq)...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            args[key] = value
            working = working.replacingOccurrences(of: token, with: " ")
        }

        // 2) choices 扫描
        for spec in specs {
            guard args[spec.name] == nil, let choices = spec.choices else { continue }
            let lower = working.lowercased()
            for choice in choices where lower.contains(choice.lowercased()) {
                let canonical = spec.valueMap?[choice.lowercased()] ?? choice.lowercased()
                args[spec.name] = canonical
                if let range = working.range(of: choice, options: .caseInsensitive) {
                    working.removeSubrange(range)
                }
                break
            }
        }

        // 3) 位置参数
        let remaining = commandTokens(working).map { token in
            guard token.count >= 2, token.first == "\"", token.last == "\"" else { return token }
            return String(token.dropFirst().dropLast())
        }
        var index = 0
        for spec in specs where args[spec.name] == nil {
            switch spec.kind {
            case .value:
                guard index < remaining.count else { continue }
                args[spec.name] = remaining[index]
                index += 1
            case .rest:
                let rest = remaining.dropFirst(index).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rest.isEmpty else { continue }
                args[spec.name] = rest
                index = remaining.count
            }
        }

        return args
    }

    private static func isURLOrCode(_ text: String) -> Bool {
        if text.contains("```") {
            return true
        }
        let pattern = #"(?i)\b(?:https?|ftp)://[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Split command input while preserving quoted values and escaped quotes.
    /// The parser bounds the complete submission before calling this helper;
    /// the token cap additionally prevents pathological argument fan-out.
    private static func commandTokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var escaped = false

        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
