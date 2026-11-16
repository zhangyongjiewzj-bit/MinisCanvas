import Foundation

/// A command request that is ready for Policy/Approval routing.
///
/// Creating this value is intentionally side-effect free. The Composer slice
/// must not call a command's execution closure before the policy boundary.
public struct PendingCommandRequest: Sendable, Equatable {
    public let id: UUID
    public let commandID: String
    public let args: [String: String]
    public let requiresPolicyApproval: Bool

    public init(
        id: UUID,
        commandID: String,
        args: [String: String] = [:],
        requiresPolicyApproval: Bool
    ) {
        self.id = id
        self.commandID = CommandDefinition.canonicalID(commandID)
        self.args = args
        self.requiresPolicyApproval = requiresPolicyApproval
    }
}

/// Risk shown beside a Composer slash command. This is presentation and
/// routing metadata; a high-risk command still requires the Policy/Approval
/// boundary before any consumer may execute it.
public enum ComposerCommandRisk: String, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high

    public var zhLabel: String {
        switch self {
        case .low: "低风险"
        case .medium: "中风险"
        case .high: "高风险"
        }
    }

    public var enLabel: String {
        switch self {
        case .low: "Low risk"
        case .medium: "Medium risk"
        case .high: "High risk"
        }
    }

    public var displayLabel: String { "\(zhLabel) / \(enLabel)" }
}

/// Bilingual Composer command metadata kept beside the canonical command
/// registration. `argumentSpecs` is the same source used by the parser, so
/// completion can explain the accepted parameters without a second schema.
public struct ComposerCommandMetadata: Sendable {
    public let id: String
    public let zhTitle: String
    public let enTitle: String
    public let zhSummary: String
    public let enSummary: String
    public let aliases: [String]
    public let category: CommandCategory
    public let risk: ComposerCommandRisk
    public let requiresPolicyApproval: Bool
    public let parameterSummary: String
    public let argumentSpecs: [CommandArgumentSpec]

    public init(
        id: String,
        zhTitle: String,
        enTitle: String,
        zhSummary: String,
        enSummary: String,
        aliases: [String] = [],
        category: CommandCategory,
        risk: ComposerCommandRisk,
        requiresPolicyApproval: Bool = false,
        parameterSummary: String = "无 / none",
        argumentSpecs: [CommandArgumentSpec] = []
    ) {
        self.id = CommandDefinition.canonicalID(id)
        self.zhTitle = zhTitle
        self.enTitle = enTitle
        self.zhSummary = zhSummary
        self.enSummary = enSummary
        self.aliases = aliases
        self.category = category
        self.risk = risk
        self.requiresPolicyApproval = requiresPolicyApproval
        self.parameterSummary = parameterSummary
        self.argumentSpecs = argumentSpecs
    }
}

/// 命令注册表：注册、分类查询、搜索与执行。
///
/// 线程安全（内部 NSLock），可跨任务共享。默认提供 `shared` 单例，
/// 已预置 env/log/backend/session/memory/workflow/settings 命令（见
/// `PresetCommands`）；测试或嵌入方可用 `CommandRegistry(commands:)`
/// 构建带自定义依赖的实例。
public final class CommandRegistry: @unchecked Sendable {

    /// The complete Phase 3 slash vocabulary. The order is the completion
    /// order and is deliberately stable for keyboard users and VoiceOver.
    /// It mirrors the App Composer menu (W4-SLASHMENU-036) so a menu row is
    /// dispatchable exactly when the canonical pipeline can consume it.
    ///
    /// Source: dangling donor fbef9ecb9 (21-command catalog) plus the
    /// canonically routed `model` ID already present in the baseline. The
    /// donor's `provider.use` absorbed the `model`/`模型` aliases; that
    /// absorption is intentionally NOT consumed here because `model` keeps
    /// its own canonical row (`/模型` → `model` stays unambiguous).
    public static let composerCommandMetadata: [ComposerCommandMetadata] = [
        ComposerCommandMetadata(
            id: "help", zhTitle: "帮助", enTitle: "Help",
            zhSummary: "显示中英文命令帮助", enSummary: "Show bilingual command help",
            aliases: ["帮助", "help"], category: .session, risk: .low,
            parameterSummary: "命令 ID / command id（可选）",
            argumentSpecs: [CommandArgumentSpec(
                name: "command_id", label: "命令 ID / command id", required: false
            )]
        ),
        ComposerCommandMetadata(
            id: "commands", zhTitle: "命令列表", enTitle: "Commands",
            zhSummary: "列出可用命令和快捷键", enSummary: "List commands and shortcuts",
            aliases: ["命令", "命令列表", "commands"], category: .session, risk: .low,
            parameterSummary: "分类 / category（可选）",
            argumentSpecs: [CommandArgumentSpec(
                name: "category", label: "分类 / category", required: false
            )]
        ),
        ComposerCommandMetadata(
            id: "boundary", zhTitle: "安全边界", enTitle: "Safety Boundary",
            zhSummary: "查看当前 Agent 安全边界", enSummary: "Show current Agent safety boundary",
            aliases: ["边界", "安全边界", "boundary"], category: .agent, risk: .low
        ),
        ComposerCommandMetadata(
            id: "boundary.set", zhTitle: "设置安全边界", enTitle: "Set Safety Boundary",
            zhSummary: "设置边界 profile", enSummary: "Set boundary profile",
            aliases: ["设置边界", "设置安全边界", "boundary set"], category: .agent,
            risk: .high, requiresPolicyApproval: true,
            parameterSummary: "profile/options（必填）",
            argumentSpecs: [CommandArgumentSpec(
                name: "profile", label: "边界 profile / boundary profile", kind: .rest
            )]
        ),
        ComposerCommandMetadata(
            id: "add-dir", zhTitle: "添加目录", enTitle: "Add Directory",
            zhSummary: "审批后扩展目录范围；仅当前会话、仅内存，不持久，重启后需重新添加",
            enSummary: "Add a directory for this session in memory only; add it again after restarting",
            aliases: ["添加目录", "add-dir"], category: .agent,
            risk: .high, requiresPolicyApproval: true,
            parameterSummary: "绝对目录路径 / absolute directory path（必填）",
            argumentSpecs: [CommandArgumentSpec(name: "path", label: "目录路径 / directory path", kind: .rest)]
        ),
        ComposerCommandMetadata(
            id: "status", zhTitle: "当前状态", enTitle: "Current Status",
            zhSummary: "查看当前会话和任务状态", enSummary: "Show session and task status",
            aliases: ["状态", "当前状态", "status"], category: .session, risk: .low
        ),
        ComposerCommandMetadata(
            id: "copy", zhTitle: "复制回复", enTitle: "Copy Reply",
            zhSummary: "复制倒数第 N 条已完成回复", enSummary: "Copy the Nth latest completed reply",
            aliases: ["copy"], category: .session, risk: .low,
            parameterSummary: "N（可选，默认 1，正整数）",
            argumentSpecs: [CommandArgumentSpec(name: "n", label: "倒数序号 / N", required: false)]
        ),
        ComposerCommandMetadata(
            id: "tasks", zhTitle: "任务列表", enTitle: "Task List",
            zhSummary: "打开任务列表", enSummary: "Open task list",
            aliases: ["任务", "任务列表", "tasks"], category: .session, risk: .low
        ),
        ComposerCommandMetadata(
            id: "stop", zhTitle: "停止任务", enTitle: "Stop Task",
            zhSummary: "停止当前生成或任务", enSummary: "Stop current generation or task",
            aliases: ["停止", "停止任务", "stop"], category: .session, risk: .medium
        ),
        ComposerCommandMetadata(
            id: "compact", zhTitle: "压缩上下文", enTitle: "Compact Context",
            zhSummary: "压缩当前上下文", enSummary: "Compact current context",
            aliases: ["压缩", "压缩上下文", "compact"], category: .session,
            risk: .medium, requiresPolicyApproval: true,
            parameterSummary: "指引 / hint（可选）",
            argumentSpecs: [CommandArgumentSpec(name: "hint", label: "压缩指引 / hint", required: false, kind: .rest)]
        ),
        ComposerCommandMetadata(
            id: "retry", zhTitle: "重试任务", enTitle: "Retry Task",
            zhSummary: "重试上一个失败任务", enSummary: "Retry the last failed task",
            aliases: ["重试", "重试任务", "retry"], category: .session, risk: .medium
        ),
        ComposerCommandMetadata(
            id: "canvas.run", zhTitle: "执行画布", enTitle: "Run Canvas",
            zhSummary: "执行当前画布", enSummary: "Run current canvas",
            aliases: ["执行画布", "运行画布", "canvas run"], category: .canvas,
            risk: .high, requiresPolicyApproval: true,
            parameterSummary: "node/task scope（可选）",
            argumentSpecs: [CommandArgumentSpec(
                name: "scope", label: "节点或任务范围 / node or task scope", required: false, kind: .rest
            )]
        ),
        ComposerCommandMetadata(
            id: "canvas.cancel", zhTitle: "取消画布", enTitle: "Cancel Canvas",
            zhSummary: "取消当前画布执行", enSummary: "Cancel current canvas run",
            aliases: ["取消画布", "取消画布执行", "canvas cancel"], category: .canvas,
            risk: .medium,
            parameterSummary: "run id（可选）",
            argumentSpecs: [CommandArgumentSpec(
                name: "run_id", label: "运行 ID / run id", required: false
            )]
        ),
        ComposerCommandMetadata(
            id: "canvas.minimap", zhTitle: "画布小地图", enTitle: "Canvas Minimap",
            zhSummary: "显示或隐藏小地图", enSummary: "Toggle canvas minimap",
            aliases: ["小地图", "画布小地图", "canvas minimap"], category: .canvas, risk: .medium,
            parameterSummary: "on/off（必填）",
            argumentSpecs: [CommandArgumentSpec(
                name: "mode", label: "模式 / mode", choices: ["on", "off", "开启", "关闭"],
                valueMap: ["on": "on", "off": "off", "开启": "on", "关闭": "off"]
            )]
        ),
        ComposerCommandMetadata(
            id: "provider", zhTitle: "当前提供商", enTitle: "Current Provider",
            zhSummary: "查看当前 Provider 和 Model", enSummary: "Show current Provider and Model",
            aliases: ["提供商", "当前提供商", "provider"], category: .backend, risk: .low
        ),
        ComposerCommandMetadata(
            id: "provider.use", zhTitle: "选择提供商", enTitle: "Select Provider",
            zhSummary: "选择 Provider 和 Model", enSummary: "Select Provider and Model",
            aliases: ["选择提供商", "切换提供商", "provider use"],
            category: .backend, risk: .high, requiresPolicyApproval: true,
            parameterSummary: "provider/model（必填）",
            argumentSpecs: [CommandArgumentSpec(
                name: "provider_model", label: "Provider/Model", kind: .rest
            )]
        ),
        // /model only opens the existing picker. Applying a selection retains
        // the picker's readiness-backed boundary; opening needs no approval.
        ComposerCommandMetadata(
            id: "model", zhTitle: "模型", enTitle: "Model",
            zhSummary: "选择或切换当前模型", enSummary: "Select or switch the model",
            aliases: ["模型", "model"], category: .backend,
            risk: .low
        ),
        ComposerCommandMetadata(
            id: "workflow", zhTitle: "运行工作流", enTitle: "Run Workflow",
            zhSummary: "运行工作流", enSummary: "Run workflow",
            aliases: ["工作流", "运行工作流", "workflow"], category: .workflow,
            risk: .high, requiresPolicyApproval: true,
            parameterSummary: "模板 + 参数 / template + args（模板必填）",
            argumentSpecs: [
                CommandArgumentSpec(name: "template", label: "模板 / template"),
                CommandArgumentSpec(name: "args", label: "参数 / args", required: false, kind: .rest),
            ]
        ),
        ComposerCommandMetadata(
            id: "approve", zhTitle: "批准请求", enTitle: "Approve Request",
            zhSummary: "批准当前权限请求", enSummary: "Approve pending request",
            aliases: ["批准", "批准请求", "approve"], category: .agent,
            risk: .high, requiresPolicyApproval: true
        ),
        ComposerCommandMetadata(
            id: "reject", zhTitle: "拒绝请求", enTitle: "Reject Request",
            zhSummary: "拒绝当前权限请求", enSummary: "Reject pending request",
            aliases: ["拒绝", "拒绝请求", "reject"], category: .agent, risk: .medium
        ),
        ComposerCommandMetadata(
            id: "memory", zhTitle: "记忆范围", enTitle: "Memory Scope",
            zhSummary: "查看当前记忆范围", enSummary: "Show memory scope",
            aliases: ["记忆", "记忆范围", "memory"], category: .memory, risk: .low
        ),
        ComposerCommandMetadata(
            id: "memory.propose", zhTitle: "提议记忆变更", enTitle: "Propose Memory Change",
            zhSummary: "提交记忆变更提案", enSummary: "Propose a memory change",
            aliases: ["提议记忆", "提交记忆提案", "memory propose"], category: .memory,
            risk: .high, requiresPolicyApproval: true,
            parameterSummary: "文本 / text（必填）",
            argumentSpecs: [CommandArgumentSpec(
                name: "text", label: "文本 / text", kind: .rest
            )]
        ),
        ComposerCommandMetadata(
            id: "skills", zhTitle: "技能状态", enTitle: "Skill Status",
            zhSummary: "查看 Skill 状态", enSummary: "Show Skill status",
            aliases: ["技能", "技能状态", "skills"], category: .agent, risk: .low
        ),
        ComposerCommandMetadata(
            id: "permissions", zhTitle: "权限", enTitle: "Permissions",
            zhSummary: "打开现有安全设置页", enSummary: "Open existing safety settings",
            aliases: ["permissions"], category: .settings, risk: .low
        ),
        ComposerCommandMetadata(
            id: "mcp", zhTitle: "MCP 管理", enTitle: "MCP",
            zhSummary: "打开 MCP 管理页", enSummary: "Open MCP settings",
            aliases: ["mcp"], category: .settings, risk: .low
        ),
        ComposerCommandMetadata(
            id: "context", zhTitle: "上下文", enTitle: "Context",
            zhSummary: "查看当前上下文占用与来源", enSummary: "Inspect context occupancy and sources",
            aliases: ["context"], category: .session, risk: .low
        ),
        ComposerCommandMetadata(
            id: "clear", zhTitle: "新会话", enTitle: "Clear",
            zhSummary: "新建会话，旧会话仍可恢复", enSummary: "Start a new conversation and retain the old one",
            aliases: ["clear"], category: .session, risk: .low
        ),
        ComposerCommandMetadata(
            id: "rewind", zhTitle: "回退检查点", enTitle: "Rewind",
            zhSummary: "选择检查点并确认恢复", enSummary: "Select and confirm a checkpoint restore",
            aliases: ["rewind"], category: .session, risk: .low
        ),
        ComposerCommandMetadata(
            id: "doctor", zhTitle: "环境诊断", enTitle: "Doctor",
            zhSummary: "打开环境诊断与配置检查", enSummary: "Open environment diagnostics",
            aliases: ["doctor"], category: .settings, risk: .low
        ),
        ComposerCommandMetadata(
            id: "usage", zhTitle: "用量", enTitle: "Usage",
            zhSummary: "查看真实用量记录", enSummary: "Inspect recorded usage",
            aliases: ["usage", "cost"], category: .settings, risk: .low
        ),
        ComposerCommandMetadata(
            id: "export", zhTitle: "导出会话", enTitle: "Export",
            zhSummary: "脱敏后导出会话为 Markdown", enSummary: "Export a redacted Markdown transcript",
            aliases: ["export"], category: .session, risk: .low
        ),
        ComposerCommandMetadata(
            id: "rename", zhTitle: "重命名会话", enTitle: "Rename",
            zhSummary: "修改当前会话名称", enSummary: "Rename the current conversation",
            aliases: ["rename"], category: .session, risk: .low,
            parameterSummary: "名称 / title（可选）",
            argumentSpecs: [CommandArgumentSpec(name: "title", label: "名称 / title", required: false, kind: .rest)]
        ),
        ComposerCommandMetadata(
            id: "resume", zhTitle: "恢复会话", enTitle: "Resume",
            zhSummary: "选择已有会话继续", enSummary: "Choose an existing conversation",
            aliases: ["resume"], category: .session, risk: .low
        ),
        ComposerCommandMetadata(
            id: "plan", zhTitle: "计划模式", enTitle: "Plan",
            zhSummary: "进入计划模式，批准后执行", enSummary: "Enter plan mode before approved execution",
            aliases: ["plan"], category: .agent, risk: .low,
            parameterSummary: "描述 / description（可选）",
            argumentSpecs: [CommandArgumentSpec(name: "description", label: "计划描述 / description", required: false, kind: .rest)]
        ),
        ComposerCommandMetadata(
            id: "shortcuts", zhTitle: "快捷键", enTitle: "Shortcuts",
            zhSummary: "查看或设置快捷键", enSummary: "Show or configure shortcuts",
            aliases: ["快捷键", "快捷键设置", "shortcuts"], category: .settings, risk: .low,
            parameterSummary: "action（可选）",
            argumentSpecs: [CommandArgumentSpec(
                name: "action", label: "操作 / action", required: false, kind: .rest
            )]
        ),
    ]

    /// Composer commands use these stable IDs across localized aliases.
    /// Membership in this set is the routing gate: an ID outside it is never
    /// treated as a Composer slash command (fail-closed), and prose must not
    /// resolve into these commands through natural-language matching.
    public static let composerCommandIDs: Set<String> = Set(
        composerCommandMetadata.map(\.id)
    )

    /// Read-only commands that may be consumed without waiting for the active turn.
    /// All other commands keep the existing O06 queue boundary.
    public static func runsDuringGeneration(_ commandID: String) -> Bool {
        // stop/reject act on the in-flight turn or its pending approval card;
        // queueing them behind that turn would make them unusable (N2).
        ["status", "tasks", "usage", "permissions", "stop", "reject"]
            .contains(CommandDefinition.canonicalID(commandID))
    }

    /// Commands that can change session state or routing must cross
    /// Policy/Approval before any consumer executes them.
    private static let composerPolicyApprovalIDs: Set<String> = Set(
        composerCommandMetadata.filter(\.requiresPolicyApproval).map(\.id)
    )

    /// 应用级共享注册表。
    ///
    /// Keep this bootstrap side-effect free.  The app's packaged-field
    /// profile is injected by its composition root; constructing default
    /// `CommandDependencies` here would resolve `SessionStore.defaultDirectory`
    /// before that profile exists and can trap on a field launch with an
    /// incomplete environment contract.  Profile-owned preset commands are
    /// assembled by `AppCommandCatalog` with explicit dependencies.
    public static let shared = CommandRegistry()

    private let lock = NSLock()
    private var commandsByID: [String: CommandDefinition] = [:]
    private var order: [String] = []  // 注册顺序，保证查询结果稳定

    public init(commands: [CommandDefinition] = []) {
        register(commands)
    }

    // MARK: - 注册

    /// 注册一条命令；同 id 覆盖旧定义（保持原注册位置）。
    public func register(_ command: CommandDefinition) {
        lock.lock()
        defer { lock.unlock() }
        if commandsByID[command.id] == nil {
            order.append(command.id)
        }
        commandsByID[command.id] = command
    }

    /// 批量注册。
    public func register(_ commands: [CommandDefinition]) {
        for command in commands { register(command) }
    }

    /// Register the side-effect-free Phase 3 slash vocabulary used by the
    /// Composer. Localized aliases resolve to the same canonical IDs. The
    /// registered closures never execute work: a Composer command must first
    /// become a `PendingCommandRequest` and cross the Policy/Approval
    /// boundary, so registering an ID only enables routing, not execution.
    public func registerComposerCommands() {
        register(Self.composerCommandMetadata.map { metadata in
            CommandDefinition(
                id: metadata.id,
                title: metadata.zhTitle,
                keywords: [metadata.zhTitle, metadata.enTitle, metadata.zhSummary, metadata.enSummary],
                aliases: metadata.aliases,
                category: metadata.category,
                requiresConfirmation: metadata.requiresPolicyApproval,
                argumentSpecs: metadata.argumentSpecs,
                customParse: Self.composerArgumentParser(for: metadata.id)
            ) { _ in
                .failure("Composer 命令必须先创建 pending request")
            }
        })
    }

    /// AppCommandCatalog installs the same metadata into its production
    /// registry; both consumers must use this one parser definition.
    public static func composerArgumentParser(
        for commandID: String
    ) -> (@Sendable (String) -> [String: String]?)? {
        if commandID == "compact" || commandID == "rename" || commandID == "plan" || commandID == "add-dir" {
            let key = commandID == "add-dir" ? "path"
                : (commandID == "compact" ? "hint" : (commandID == "plan" ? "description" : "title"))
            return { text in
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? [:] : [key: value]
            }
        }
        guard commandID == "workflow" else { return nil }
        return { Self.parseComposerWorkflowArguments($0) }
    }

    /// Keep the runner's input syntax intact across the Composer approval
    /// boundary. The generic key=value extractor consumes novel=... before
    /// assigning the optional rest argument and truncates unquoted spaces.
    private static func parseComposerWorkflowArguments(_ text: String) -> [String: String]? {
        let parts = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return nil }
        let token = String(first)
        let template: String
        if token.hasPrefix("template=") {
            template = String(token.dropFirst("template=".count))
        } else {
            guard !token.contains("=") else { return [:] }
            template = token
        }
        var arguments = ["template": template]
        if parts.count == 2 {
            let rest = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawInputs = rest.hasPrefix("args=")
                ? String(rest.dropFirst("args=".count)) : rest
            if !rawInputs.isEmpty { arguments["args"] = rawInputs }
        }
        return arguments
    }

    /// Returns the display metadata for a canonical ID or localized alias.
    public static func composerMetadata(for id: String) -> ComposerCommandMetadata? {
        let canonical = CommandDefinition.canonicalID(id)
        return composerCommandMetadata.first { metadata in
            metadata.id == canonical
                || metadata.aliases.contains { CommandDefinition.canonicalID($0) == canonical }
        }
    }

    /// Build a request for the Policy/Approval layer without executing it.
    public func makePendingRequest(
        for parsed: ParsedCommand,
        requestID: UUID = UUID()
    ) -> PendingCommandRequest? {
        guard let parsedCommand = parsed.command,
              let command = command(id: parsedCommand.id)
        else {
            return nil
        }

        let requiresPolicyApproval =
            Self.composerPolicyApprovalIDs.contains(command.id)
            || command.requiresConfirmation
        return PendingCommandRequest(
            id: requestID,
            commandID: command.id,
            args: parsed.args,
            requiresPolicyApproval: requiresPolicyApproval
        )
    }

    /// Validate a Composer slash intent before it enters Policy/Approval.
    /// `makePendingRequest` remains the low-level, side-effect-free projection
    /// used by persisted requests; an interactive Composer consumer must use
    /// this result so missing or invalid arguments never become an approvable
    /// pending request. The returned error is suitable for a visible local
    /// command response and must not be sent to the Provider as user prose.
    public func validatedComposerPendingRequest(
        for parsed: ParsedCommand,
        requestID: UUID = UUID()
    ) -> Result<PendingCommandRequest, CommandExecutionError> {
        guard parsed.disposition == .command,
              let parsedCommand = parsed.command,
              Self.composerCommandIDs.contains(parsedCommand.id),
              let command = command(id: parsedCommand.id)
        else {
            return .failure(.unknownCommand(parsed.command?.id ?? ""))
        }

        if case .disabled(let reason) = command.currentAvailability {
            return .failure(.disabled(commandID: command.id, reason: reason))
        }

        var normalizedArgs = parsed.args
        for spec in command.argumentSpecs {
            let value = normalizedArgs[spec.name]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                if spec.required {
                    return .failure(.missingArgument(commandID: command.id, argument: spec.name))
                }
                normalizedArgs.removeValue(forKey: spec.name)
                continue
            }

            guard let choices = spec.choices else {
                normalizedArgs[spec.name] = value
                continue
            }
            let canonical = spec.valueMap?[value.lowercased()] ?? value.lowercased()
            let accepted = Set(choices.map { choice in
                spec.valueMap?[choice.lowercased()] ?? choice.lowercased()
            })
            guard accepted.contains(canonical) else {
                return .failure(.invalidArgument(
                    commandID: command.id,
                    argument: spec.name,
                    reason: "可用值 / allowed values: \(choices.joined(separator: ", "))"
                ))
            }
            normalizedArgs[spec.name] = canonical
        }

        let requiresPolicyApproval =
            Self.composerPolicyApprovalIDs.contains(command.id)
            || command.requiresConfirmation
        return .success(PendingCommandRequest(
            id: requestID,
            commandID: command.id,
            args: normalizedArgs,
            requiresPolicyApproval: requiresPolicyApproval
        ))
    }

    /// Reconcile a persisted Composer request against the current registry
    /// without executing it. This is the recovery seam for a renamed,
    /// disabled, or removed command.
    public enum PendingCommandRecovery: Sendable, Equatable {
        case ready
        case confirmationRequired
        case disabled(reason: String)
        case missing
    }

    public func recoverPendingRequest(_ request: PendingCommandRequest) -> PendingCommandRecovery {
        guard let command = command(id: request.commandID) else { return .missing }
        switch command.currentAvailability {
        case .disabled(let reason): return .disabled(reason: reason)
        case .enabled:
            return command.requiresConfirmation || request.requiresPolicyApproval
                ? .confirmationRequired
                : .ready
        }
    }

    // MARK: - 查询

    /// 命令总数。
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return commandsByID.count
    }

    /// 按 id 精确查找（大小写不敏感；也接受 alias）。
    public func command(id: String) -> CommandDefinition? {
        let needle = CommandDefinition.canonicalID(id)
        lock.lock(); defer { lock.unlock() }
        if let direct = commandsByID[needle] { return direct }
        // Alias resolution follows registration order, never Dictionary order.
        return order.compactMap { commandsByID[$0] }.first { command in
            command.aliases.contains { $0.lowercased() == needle }
        }
    }

    /// 全部命令，按注册顺序。
    public func allCommands() -> [CommandDefinition] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { commandsByID[$0] }
    }

    /// 指定分类下的全部命令，按注册顺序。
    public func commands(category: CommandCategory) -> [CommandDefinition] {
        allCommands().filter { $0.category == category }
    }

    /// 当前存在的分类（按注册顺序去重）。
    public func categories() -> [CommandCategory] {
        var seen = Set<CommandCategory>()
        return allCommands().compactMap { command in
            guard seen.insert(command.category).inserted else { return nil }
            return command.category
        }
    }

    /// 文本检索：id/title/keywords/aliases 子串匹配，按相关度排序。
    /// 相关度：id 前缀 > id 包含 > title 包含 > keyword/alias 包含。
    public func search(_ query: String, limit: Int = 8) -> [CommandDefinition] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(allCommands().prefix(limit)) }

        struct Scored { let command: CommandDefinition; let rank: Int }
        var scored: [Scored] = []
        for command in allCommands() {
            let id = command.id.lowercased()
            let title = command.title.lowercased()
            let rank: Int
            if id.hasPrefix(q) {
                rank = 0
            } else if id.contains(q) {
                rank = 1
            } else if title.contains(q) {
                rank = 2
            } else if command.keywords.contains(where: { $0.lowercased().contains(q) })
                || command.aliases.contains(where: { $0.lowercased().contains(q) }) {
                rank = 3
            } else {
                continue
            }
            scored.append(Scored(command: command, rank: rank))
        }
        return scored
            .sorted { $0.rank == $1.rank ? $0.command.id < $1.command.id : $0.rank < $1.rank }
            .prefix(limit)
            .map(\.command)
    }

    // MARK: - 执行

    /// 执行命令（id 或 alias）。`confirmation` 为 true 时跳过
    /// `requiresConfirmation` 检查。
    public func execute(
        id: String,
        args: [String: String] = [:],
        confirmation: Bool = false
    ) async throws -> CommandResult {
        guard let command = command(id: id) else {
            throw CommandExecutionError.unknownCommand(id)
        }

        if case .disabled(let reason) = command.currentAvailability {
            throw CommandExecutionError.disabled(commandID: command.id, reason: reason)
        }

        if command.requiresConfirmation && !confirmation {
            throw CommandExecutionError.confirmationRequired(command.id)
        }

        for spec in command.argumentSpecs where spec.required {
            guard let value = args[spec.name], !value.isEmpty else {
                throw CommandExecutionError.missingArgument(commandID: command.id, argument: spec.name)
            }
        }

        return try await command.execute(args)
    }
}
