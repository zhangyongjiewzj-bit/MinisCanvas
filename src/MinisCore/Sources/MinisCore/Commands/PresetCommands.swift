import Foundation

// MARK: - CommandDependencies

/// 预置命令依赖的注入容器。默认值指向应用级单例；测试时传入
/// 临时目录构建的 store，避免污染真实数据。
public struct CommandDependencies: Sendable {
    public var env: EnvVarStore
    public var log: LogManager
    public var backends: LocalBackends
    public var sessions: SessionStore?
    public var memory: MemoryStore?
    public var memoryProposalConsumer: MemoryProposalConsumer?
    public var memoryScopeProvider: (@MainActor @Sendable () -> MemoryScope?)?
    public var workflows: WorkflowStore
    /// 工作流文本生成实现；nil 时 `workflow.run` 返回「未配置」提示。
    public var workflowProvider: (any WorkflowProvider)?

    public init(
        env: EnvVarStore? = nil,
        log: LogManager? = nil,
        backends: LocalBackends? = nil,
        sessions: SessionStore? = SessionStore(directory: SessionStore.defaultDirectory),
        memory: MemoryStore? = nil,
        memoryProposalConsumer: MemoryProposalConsumer? = nil,
        memoryScopeProvider: (@MainActor @Sendable () -> MemoryScope?)? = nil,
        workflows: WorkflowStore? = nil,
        workflowProvider: (any WorkflowProvider)? = nil
    ) {
        self.env = env ?? EnvVarStore(directory: EnvVarStore.defaultDirectory())
        self.log = log ?? .shared
        self.backends = backends ?? .shared
        self.sessions = sessions
        self.memory = memory ?? MemoryStore(directory: SessionStore.defaultDirectory)
        self.memoryProposalConsumer = memoryProposalConsumer
        self.memoryScopeProvider = memoryScopeProvider
        self.workflows = workflows ?? .shared
        self.workflowProvider = workflowProvider
    }
}

// MARK: - PresetCommands

/// 预置命令集：env / log / backend / session / memory / workflow / settings。
///
/// `settings.*` 属于 UI 路由命令：核心层只负责注册与参数解析，
/// MinisCanvasApp 应在执行前按 id 拦截并打开设置面板/重置设置。
public enum PresetCommands {

    public static func all(dependencies: CommandDependencies) -> [CommandDefinition] {
        [
            envList(dependencies),
            envSet(dependencies),
            envDelete(dependencies),
            logRecent(dependencies),
            logLevel(dependencies),
            backendStatus(dependencies),
            backendList(dependencies),
            sessionList(dependencies),
            sessionNew(dependencies),
            memoryList(dependencies),
            memoryAdd(dependencies),
            workflowRun(dependencies),
            settingsOpen(),
            settingsReset(),
        ]
    }

    // MARK: - env

    private static func envList(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "env.list",
            title: "列出环境变量",
            keywords: ["环境变量", "列出环境变量", "查看环境变量", "env list"],
            aliases: ["envs", "环境变量列表"],
            category: .environment
        ) { _ in
            let entries = deps.env.allEnvVars
            guard !entries.isEmpty else { return .success("环境变量：无") }
            let lines = entries.map { entry -> String in
                let shown: String
                if entry.isSecret || entry.valueInKeychain {
                    shown = EnvVarRedactor.redact(entry.value)
                } else if deps.env.mayDisplayValueInList(entry) {
                    shown = entry.value.count > 60
                        ? String(entry.value.prefix(60)) + "…"
                        : entry.value
                } else {
                    shown = "[hidden]"
                }
                return entry.isSecret || entry.valueInKeychain
                    ? "\(entry.name) = \(shown) [secret]"
                    : "\(entry.name) = \(shown)"
            }
            return .success("环境变量（\(entries.count) 个）：\n" + lines.joined(separator: "\n"))
        }
    }

    private static func envSet(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "env.set",
            title: "设置环境变量",
            keywords: ["设置环境变量", "配置环境变量", "环境变量设置", "设置"],
            aliases: ["envset", "env-set"],
            category: .environment,
            argumentSpecs: [
                CommandArgumentSpec(name: "name", label: "变量名"),
                CommandArgumentSpec(name: "value", label: "变量值", kind: .rest),
            ],
            customParse: { text in parseEnvSet(text) }
        ) { args in
            guard let name = args["name"], let value = args["value"] else {
                throw CommandExecutionError.missingArgument(commandID: "env.set", argument: "name/value")
            }
            guard deps.env.setEnvVar(name: name, value: value) else {
                throw CommandExecutionError.invalidArgument(
                    commandID: "env.set", argument: "name",
                    reason: "\(name) 不是合法的环境变量名"
                )
            }
            let masked = EnvVarRedactor.redact(value)
            return .success("已设置 \(EnvVarStore.canonicalName(name)) = \(masked)")
        }
    }

    private static func envDelete(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "env.delete",
            title: "删除环境变量",
            keywords: ["删除环境变量", "环境变量删除", "删除"],
            aliases: ["envdelete", "env-del"],
            category: .environment,
            argumentSpecs: [
                CommandArgumentSpec(name: "name", label: "变量名"),
            ],
            customParse: { text in parseEnvDelete(text) }
        ) { args in
            guard let name = args["name"] else {
                throw CommandExecutionError.missingArgument(commandID: "env.delete", argument: "name")
            }
            return deps.env.deleteEnvVar(name: name)
                ? .success("已删除环境变量 \(EnvVarStore.canonicalName(name))")
                : .failure("环境变量 \(EnvVarStore.canonicalName(name)) 不存在")
        }
    }

    /// env.set 参数提取：支持 `NAME=value`、`NAME 为 value`、`NAME 是 value`、
    /// 以及「设置 NAME value」三种形态。提取失败返回 nil（供匹配决胜）。
    private static func parseEnvSet(_ text: String) -> [String: String]? {
        var t = text
        t = t.replacingOccurrences(
            of: "^(设置|修改|更新|配置|把)\\s*",
            with: "", options: .regularExpression
        )
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // NAME=value（等号前后可有空格）
        if let eq = t.firstIndex(of: "=") {
            let name = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard EnvVarStore.isValidName(name), !value.isEmpty else { return nil }
            return ["name": name, "value": value]
        }
        // NAME 为 value / NAME 是 value
        for sep in ["为", "是"] {
            if let r = t.range(of: sep) {
                let name = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard EnvVarStore.isValidName(name), !value.isEmpty else { return nil }
                return ["name": name, "value": value]
            }
        }
        // 位置形态：第一个「全大写/带下划线」的合法变量名当 name，其后为 value
        let tokens = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let nameToken = tokens.first(where: {
            EnvVarStore.isValidName($0) && $0.uppercased() == $0 && $0.count >= 2
        }) else { return nil }
        let name = nameToken
        let value = t.replacingOccurrences(of: nameToken, with: "", options: [.anchored])
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return ["name": name, "value": value]
    }

    private static func parseEnvDelete(_ text: String) -> [String: String]? {
        var t = text
        t = t.replacingOccurrences(of: "^(删除|移除|删掉)\\s*", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let token = tokens.first(where: { EnvVarStore.isValidName($0) }) else { return nil }
        return ["name": token]
    }

    // MARK: - log

    private static func logRecent(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "log.recent",
            title: "查看最近日志",
            keywords: ["日志", "最近日志", "查看日志", "log"],
            aliases: ["logs", "日志记录"],
            category: .logging,
            argumentSpecs: [
                CommandArgumentSpec(name: "limit", label: "条数", required: false),
            ]
        ) { args in
            let limit = Int(args["limit"] ?? "") ?? 20
            let text = deps.log.recentLogsText(limit: limit)
            return text.isEmpty
                ? .success("最近日志：无")
                : .success("最近 \(limit) 条日志：\n" + text)
        }
    }

    private static func logLevel(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "log.level",
            title: "设置日志级别",
            keywords: ["日志级别", "日志等级", "设置日志级别", "日志"],
            aliases: ["loglevel", "log-level"],
            category: .logging,
            argumentSpecs: [
                CommandArgumentSpec(
                    name: "level", label: "级别",
                    choices: ["debug", "info", "warn", "error", "调试", "信息", "警告", "错误"],
                    valueMap: [
                        "debug": "debug", "info": "info", "warn": "warn", "error": "error",
                        "调试": "debug", "信息": "info", "警告": "warn", "错误": "error",
                    ]
                ),
            ]
        ) { args in
            guard let raw = args["level"], let level = parseLogLevel(raw) else {
                throw CommandExecutionError.invalidArgument(
                    commandID: "log.level", argument: "level",
                    reason: "可选值：debug / info / warn / error"
                )
            }
            deps.log.minimumLevel = level
            return .success("日志级别已设为 \(level.label)（低于该级别将不再记录）")
        }
    }

    private static func parseLogLevel(_ raw: String) -> LogLevel? {
        switch raw.lowercased() {
        case "debug": .debug
        case "info": .info
        case "warn", "warning": .warn
        case "error": .error
        default: nil
        }
    }

    // MARK: - backend

    private static func backendStatus(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "backend.status",
            title: "本地后端探测状态",
            keywords: ["后端状态", "探测状态", "backend", "后端"],
            aliases: ["backendstatus", "探测"],
            category: .backend
        ) { _ in
            let configs = deps.backends.allConfigs()
            let online = await deps.backends.detect()
            let lines = LocalBackendKind.allCases.map { kind -> String in
                guard let config = configs[kind] else { return "\(kind.displayName)：未配置" }
                if !config.enabled { return "\(kind.displayName)  \(config.baseURL)  未启用" }
                let state = online[kind] == true ? "在线" : "离线"
                return "\(kind.displayName)  \(config.baseURL)  \(state)"
            }
            return .success("本地后端状态：\n" + lines.joined(separator: "\n"))
        }
    }

    private static func backendList(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "backend.list",
            title: "本地后端列表",
            keywords: ["后端列表", "backend list", "后端"],
            aliases: ["backends", "后端配置"],
            category: .backend
        ) { _ in
            let configs = deps.backends.allConfigs()
            let lines = LocalBackendKind.allCases.map { kind -> String in
                guard let config = configs[kind] else { return "\(kind.displayName)：未配置" }
                return "\(kind.displayName)  \(config.baseURL)  \(config.enabled ? "已启用" : "未启用")"
            }
            return .success("本地后端配置：\n" + lines.joined(separator: "\n"))
        }
    }

    // MARK: - session

    private static func sessionList(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "session.list",
            title: "会话列表",
            keywords: ["会话列表", "会话", "session"],
            aliases: ["sessions"],
            category: .session
        ) { _ in
            guard let store = deps.sessions else { return .failure("会话存储未配置") }
            let sessions = store.listSessions()
            guard !sessions.isEmpty else { return .success("会话：无") }
            let lines = sessions.map { "- \($0.title.isEmpty ? "（无标题）" : $0.title)  [\($0.id.prefix(8))…]" }
            return .success("会话（\(sessions.count) 个）：\n" + lines.joined(separator: "\n"))
        }
    }

    private static func sessionNew(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "session.new",
            title: "新建会话",
            keywords: ["新建会话", "新会话", "session new"],
            aliases: ["newsession", "新对话"],
            category: .session
        ) { _ in
            guard let store = deps.sessions else { return .failure("会话存储未配置") }
            let session = try store.createSession()
            return .success("已创建会话：\(session.id)")
        }
    }

    // MARK: - memory

    private static func memoryList(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "memory.list",
            title: "记忆列表",
            keywords: ["记忆列表", "记忆", "memory"],
            aliases: ["memories", "回忆"],
            category: .memory
        ) { _ in
            guard let store = deps.memory else { return .failure("记忆存储未配置") }
            let facts = try store.facts()
            guard !facts.isEmpty else { return .success("记忆：无") }
            let lines = facts.map { "- \($0.text)" }
            return .success("记忆（\(facts.count) 条）：\n" + lines.joined(separator: "\n"))
        }
    }

    private static func memoryAdd(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "memory.add",
            title: "添加记忆",
            keywords: ["记住", "添加记忆", "记录", "memory add"],
            aliases: ["remember", "记一下"],
            category: .memory,
            argumentSpecs: [
                CommandArgumentSpec(name: "text", label: "记忆内容", kind: .rest),
            ],
            customParse: { text in
                let stripped = text.replacingOccurrences(
                    of: "^(记住|记一下|添加记忆|记录|请记住)\\s*",
                    with: "", options: .regularExpression
                )
                let content = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                return ["text": content]
            }
        ) { args in
            guard let store = deps.memory,
                  let consumer = deps.memoryProposalConsumer,
                  store === consumer.store,
                  let scopeProvider = deps.memoryScopeProvider,
                  let memoryScope = await scopeProvider() else {
                return .failure("记忆写入需要当前会话和项目 scope")
            }
            guard let text = args["text"], !text.isEmpty else {
                throw CommandExecutionError.missingArgument(commandID: "memory.add", argument: "text")
            }
            let proposal = try consumer.submit(
                text: text,
                within: memoryScope,
                sourceID: "preset-command"
            )
            let factReceipt = try consumer.approve(
                proposalID: proposal.proposal.proposalID,
                within: memoryScope,
                reason: "用户明确批准"
            )
            guard let fact = try store.facts().first(where: {
                $0.id == factReceipt.subjectID
            }) else {
                return .failure("记忆写入未生成事实")
            }
            return .success("已记住：\(fact.text)")
        }
    }

    // MARK: - workflow

    private static func workflowRun(_ deps: CommandDependencies) -> CommandDefinition {
        CommandDefinition(
            id: "workflow.run",
            title: "运行工作流",
            keywords: ["运行工作流", "工作流", "workflow"],
            aliases: ["workflowrun", "跑工作流"],
            category: .workflow,
            // Workflow execution is a state-changing/remote side effect. Keep
            // the typed command visible to Policy/Approval instead of letting
            // a natural-language match execute it silently.
            requiresConfirmation: true,
            customParse: { text in parseWorkflowRun(text) }
        ) { args in
            guard let name = args["name"] else {
                throw CommandExecutionError.missingArgument(commandID: "workflow.run", argument: "name")
            }
            guard let template = deps.workflows.template(id: name) else {
                let available = deps.workflows.listTemplates().map(\.name).joined(separator: "、")
                return .failure("未找到工作流模板：\(name)。可用：\(available)")
            }
            guard let provider = deps.workflowProvider else {
                return .failure("工作流执行需要 LLM 提供者（当前未配置 workflowProvider）")
            }
            let inputs = args.filter { $0.key != "name" }
            let result = try await WorkflowRunner().run(
                template: template,
                inputs: inputs,
                provider: provider
            )
            return .success(
                "工作流「\(template.name)」完成：执行 \(result.executedStepIDs.count) 步，"
                    + "输出键：\(result.outputs.keys.sorted().joined(separator: ", "))"
            )
        }
    }

    /// workflow.run 参数提取：`name=xxx` / `key=value` 内联 token，
    /// 无 name 时取第一个剩余 token 作为模板名。
    private static func parseWorkflowRun(_ text: String) -> [String: String]? {
        var args: [String: String] = [:]
        var rest = text
        for token in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq]).lowercased()
            let value = String(token[token.index(after: eq)...])
            guard !key.isEmpty, !value.isEmpty else { continue }
            args[key] = value
            rest = rest.replacingOccurrences(of: token, with: " ")
        }
        if args["name"] == nil {
            guard let first = rest.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
            args["name"] = String(first)
        }
        return args.isEmpty ? nil : args
    }

    // MARK: - settings（UI 路由命令）

    private static func settingsOpen() -> CommandDefinition {
        CommandDefinition(
            id: "settings.open",
            title: "打开设置面板",
            keywords: ["打开设置", "设置面板", "设置"],
            aliases: ["preferences", "偏好设置"],
            category: .settings
        ) { _ in
            .success("打开设置面板（UI 层应拦截 settings.open 并展示设置视图）")
        }
    }

    private static func settingsReset() -> CommandDefinition {
        CommandDefinition(
            id: "settings.reset",
            title: "重置设置",
            keywords: ["重置设置", "恢复默认设置", "重置"],
            aliases: ["reset-settings"],
            category: .settings,
            requiresConfirmation: true
        ) { _ in
            .success("重置设置（UI 层应拦截 settings.reset 并执行恢复默认）")
        }
    }
}
