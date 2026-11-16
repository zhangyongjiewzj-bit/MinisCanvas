import Foundation

// MARK: - CommandCategory

/// 命令面板中的命令分类。
///
/// C3-1：新增 `.canvas` / `.agent` 两类，供 App 层 UI 命令
/// （建节点/执行画布/Agent 审批等）注册使用；侧栏按此分组。
/// 2026-08-06：`.documents` 分类随工作板块整体移除。
public enum CommandCategory: String, CaseIterable, Sendable {
    case environment
    case logging
    case backend
    case session
    case memory
    case workflow
    case settings
    case canvas
    case agent

    public var displayName: String {
        switch self {
        case .environment: "环境变量"
        case .logging: "日志"
        case .backend: "本地后端"
        case .session: "会话"
        case .memory: "记忆"
        case .workflow: "工作流"
        case .settings: "设置"
        case .canvas: "画布"
        case .agent: "Agent"
        }
    }
}

// MARK: - CommandArgumentKind / CommandArgumentSpec

/// 参数取值方式。
public enum CommandArgumentKind: Sendable, Equatable {
    /// 单个 token（空格分隔）。
    case value
    /// 取剩余整行。
    case rest
}

/// 命令参数规格：供 `CommandParser` 做自然语言参数提取，供
/// `CommandRegistry.execute` 做执行期必填校验。
public struct CommandArgumentSpec: Sendable, Equatable {
    public let name: String
    public let label: String
    public let required: Bool
    public let kind: CommandArgumentKind
    /// 若提供，解析器会在输入中扫描这些候选词（大小写不敏感）作为取值。
    public let choices: [String]?
    /// choices → 规范值映射（如 "调试" → "debug"）；缺省时取小写原文。
    public let valueMap: [String: String]?

    public init(
        name: String,
        label: String,
        required: Bool = true,
        kind: CommandArgumentKind = .value,
        choices: [String]? = nil,
        valueMap: [String: String]? = nil
    ) {
        self.name = name
        self.label = label
        self.required = required
        self.kind = kind
        self.choices = choices
        self.valueMap = valueMap
    }
}

// MARK: - CommandResult

/// 命令执行结果（纯文本输出，UI 层按需渲染）。
public struct CommandResult: Sendable, Equatable {
    public let ok: Bool
    public let text: String

    public init(ok: Bool, text: String) {
        self.ok = ok
        self.text = text
    }

    public static func success(_ text: String) -> CommandResult { CommandResult(ok: true, text: text) }
    public static func failure(_ text: String) -> CommandResult { CommandResult(ok: false, text: text) }
}

// MARK: - CommandExecutionError

public enum CommandExecutionError: Error, Equatable, Sendable {
    case unknownCommand(String)
    case disabled(commandID: String, reason: String)
    case missingArgument(commandID: String, argument: String)
    case invalidArgument(commandID: String, argument: String, reason: String)
    case confirmationRequired(String)

    public var errorDescription: String {
        switch self {
        case .unknownCommand(let id): return "未知命令：\(id)"
        case .disabled(let id, let reason): return "命令 \(id) 当前不可用：\(reason)"
        case .missingArgument(let id, let arg): return "命令 \(id) 缺少参数：\(arg)"
        case .invalidArgument(let id, let arg, let reason): return "命令 \(id) 参数 \(arg) 无效：\(reason)"
        case .confirmationRequired(let id): return "命令 \(id) 需要确认后才能执行"
        }
    }
}

/// Runtime availability reported by the canonical command source. Disabled
/// commands remain discoverable so the UI can explain why they cannot run.
public enum CommandAvailability: Sendable, Equatable {
    case enabled
    case disabled(reason: String)

    public var disabledReason: String? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }
}

// MARK: - CommandDefinition

/// 一条可注册、可搜索、可执行的面板命令。
///
/// - `id`：结构化 id（如 `env.list`），也是 UI 层稳定标识。
/// - `keywords`/`aliases`：供 `CommandParser` 自然语言匹配与 `search` 检索。
/// - `customParse`：可选的自定义参数提取器；返回 nil 表示无法从该文本提取
///   参数（同时作为 NL 匹配决胜的预检钩子）。
/// - `execute`：命令执行体，接收解析出的参数，异步返回文本结果。
public struct CommandDefinition: Sendable {
    public let id: String
    public let title: String
    public let keywords: [String]
    public let aliases: [String]
    public let category: CommandCategory
    public let requiresConfirmation: Bool
    public let availability: @Sendable () -> CommandAvailability
    public let argumentSpecs: [CommandArgumentSpec]
    public let customParse: (@Sendable (String) -> [String: String]?)?
    public let execute: @Sendable ([String: String]) async throws -> CommandResult

    public init(
        id: String,
        title: String,
        keywords: [String] = [],
        aliases: [String] = [],
        category: CommandCategory,
        requiresConfirmation: Bool = false,
        argumentSpecs: [CommandArgumentSpec] = [],
        availability: @escaping @Sendable () -> CommandAvailability = { .enabled },
        customParse: (@Sendable (String) -> [String: String]?)? = nil,
        execute: @escaping @Sendable ([String: String]) async throws -> CommandResult
    ) {
        self.id = Self.canonicalID(id)
        self.title = title
        self.keywords = keywords
        self.aliases = aliases
        self.category = category
        self.requiresConfirmation = requiresConfirmation
        self.availability = availability
        self.argumentSpecs = argumentSpecs
        self.customParse = customParse
        self.execute = execute
    }

    /// Canonical IDs are lower-case, trimmed, and stable across slash input,
    /// keyboard shortcuts, menu entries, and Composer pending requests.
    public static func canonicalID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var currentAvailability: CommandAvailability { availability() }

    /// 是否带任何可检索文本（id/title/keywords/aliases 之一非空）。
    public var isSearchable: Bool {
        !id.isEmpty || !title.isEmpty || !keywords.isEmpty || !aliases.isEmpty
    }
}
