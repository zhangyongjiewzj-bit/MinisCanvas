import Foundation
import Testing
@testable import MinisCore

// MARK: - Test helpers

/// 每个测试独立的临时目录（测试并行跑，绝不共享路径）。
private func makeTempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-Commands-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 全部后端禁用（不触发任何网络探测）。
private func offlineBackends() -> LocalBackends {
    let configs: [LocalBackendKind: LocalBackendConfig] = Dictionary(
        uniqueKeysWithValues: LocalBackendKind.allCases.map {
            ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
        }
    )
    return LocalBackends(configs: configs)
}

/// 临时目录构建的命令注册表 + 依赖。
private func makeRegistry(_ name: String, withProvider provider: (any WorkflowProvider)? = nil) throws -> (CommandRegistry, CommandDependencies) {
    let dir = try makeTempDir(name)
    let deps = CommandDependencies(
        env: EnvVarStore(directory: dir),
        log: LogManager(directory: dir),
        backends: offlineBackends(),
        sessions: SessionStore(directory: dir),
        memory: MemoryStore(directory: dir),
        workflows: WorkflowStore(storeDirectory: dir.appendingPathComponent("Workflows", isDirectory: true)),
        workflowProvider: provider
    )
    let memoryStore = deps.memory!
    var commandDeps = deps
    commandDeps.memoryProposalConsumer = MemoryProposalConsumer(store: memoryStore)
    commandDeps.memoryScopeProvider = { MemoryScope(sessionID: "test-session", projectID: "test-project") }
    let registry = CommandRegistry(commands: PresetCommands.all(dependencies: commandDeps))
    return (registry, commandDeps)
}

/// 测试用工作流提供者：直接返回固定文本，不调 LLM。
private struct MockWorkflowProvider: WorkflowProvider {
    func generate(prompt: String, step: WorkflowStep) async throws -> String {
        "mock-output-for-\(step.id)"
    }
}

// MARK: - Registry: register / search

struct CommandsRegistryTests {

    @Test func presetCommandsRegistered() throws {
        let (registry, _) = try makeRegistry("presets")
        #expect(registry.count == 14)
        for id in ["env.list", "env.set", "env.delete", "log.recent", "log.level",
                   "backend.status", "backend.list", "session.list", "session.new",
                   "memory.list", "memory.add", "workflow.run", "settings.open", "settings.reset"] {
            #expect(registry.command(id: id) != nil, "缺少预置命令 \(id)")
        }
    }

    @Test func searchMatchesIdTitleKeywordAlias() throws {
        let (registry, _) = try makeRegistry("search")
        // id 前缀（同 rank 按 id 字典序）
        #expect(registry.search("env.").prefix(3).map(\.id) == ["env.delete", "env.list", "env.set"])
        // title 包含（"环境变量"同时命中三个 env 命令的 title）
        #expect(registry.search("环境变量").prefix(3).map(\.id) == ["env.delete", "env.list", "env.set"])
        // 唯一 title 精确命中
        #expect(registry.search("列出环境变量").first?.id == "env.list")
        // keyword
        #expect(registry.search("日志级别").first?.id == "log.level")
        // alias
        #expect(registry.search("sessions").first?.id == "session.list")
        // 无匹配 → 空
        #expect(registry.search("zzz-not-exist").isEmpty)
    }

    @Test func categoryFilter() throws {
        let (registry, _) = try makeRegistry("category")
        let env = registry.commands(category: .environment)
        #expect(env.map(\.id) == ["env.list", "env.set", "env.delete"])
        #expect(registry.commands(category: .settings).map(\.id) == ["settings.open", "settings.reset"])
        #expect(registry.categories().contains(.backend))
    }

    @Test func registerOverridesByIdempotent() throws {
        let registry = CommandRegistry()
        let a = CommandDefinition(id: "demo.a", title: "A", category: .environment) { _ in .success("a") }
        let b = CommandDefinition(id: "demo.a", title: "A2", category: .environment) { _ in .success("b") }
        registry.register(a)
        registry.register(b)
        #expect(registry.count == 1)
    }

    @Test func aliasLookup() throws {
        let (registry, _) = try makeRegistry("alias")
        #expect(registry.command(id: "envs")?.id == "env.list")
        #expect(registry.command(id: "LOGS")?.id == "log.recent")
    }

    @Test func commandIDsAreCanonicalAndAliasOrderIsStable() {
        let registry = CommandRegistry(commands: [
            CommandDefinition(
                id: "  Demo.MixedCase  ", title: "First", aliases: ["shared"], category: .session
            ) { _ in .success("first") },
            CommandDefinition(
                id: "demo.second", title: "Second", aliases: ["shared"], category: .session
            ) { _ in .success("second") },
        ])

        #expect(registry.command(id: "DEMO.MIXEDCASE")?.id == "demo.mixedcase")
        #expect(registry.command(id: "shared")?.id == "demo.mixedcase")
        #expect(registry.allCommands().map(\.id) == ["demo.mixedcase", "demo.second"])
    }
}

// MARK: - Registry: execute

struct CommandsExecutionTests {

    @Test func envListMasksSecrets() async throws {
        let (registry, deps) = try makeRegistry("envlist")
        deps.env.setEnvVar(name: "OPENAI_API_KEY", value: "sk-test1234567890", isSecret: true)
        deps.env.setEnvVar(name: "MY_VAR", value: "hello", isSecret: false)

        let result = try await registry.execute(id: "env.list")
        #expect(result.ok)
        #expect(result.text.contains("OPENAI_API_KEY"))
        #expect(result.text.contains("[secret]"))
        // 脱敏：绝不出现在原文
        #expect(!result.text.contains("sk-test1234567890"))
        #expect(result.text.contains(EnvVarRedactor.redact("sk-test1234567890")))
        // 未明确批准公开的值不进入聊天结果。
        #expect(result.text.contains("MY_VAR = [hidden]"))
    }

    @Test func envSetAndDelete() async throws {
        let (registry, deps) = try makeRegistry("envset")
        let set = try await registry.execute(id: "env.set", args: ["name": "MY_KEY", "value": "abc123"])
        #expect(set.ok)
        #expect(deps.env.getEnvVar(name: "MY_KEY") == "abc123")
        // 非法变量名
        await #expect(throws: CommandExecutionError.self) {
            try await registry.execute(id: "env.set", args: ["name": "1BAD NAME", "value": "x"])
        }
        let del = try await registry.execute(id: "env.delete", args: ["name": "MY_KEY"])
        #expect(del.ok)
        #expect(deps.env.getEnvVar(name: "MY_KEY") == nil)
        let delMissing = try await registry.execute(id: "env.delete", args: ["name": "NOPE"])
        #expect(!delMissing.ok)
    }

    @Test func logRecentAndLevel() async throws {
        let (registry, deps) = try makeRegistry("logcmd")
        deps.log.info("hello-log", category: "Test")
        deps.log.warn("warn-log", category: "Test")

        let recent = try await registry.execute(id: "log.recent", args: ["limit": "10"])
        #expect(recent.ok)
        #expect(recent.text.contains("hello-log"))
        #expect(recent.text.contains("warn-log"))

        let level = try await registry.execute(id: "log.level", args: ["level": "error"])
        #expect(level.ok)
        #expect(deps.log.minimumLevel == .error)
        #expect(level.text.contains("ERROR"))
        // 级别提到 error 后，debug 不再记录
        deps.log.debug("should-not-appear", category: "Test")
        #expect(!deps.log.recentLogsText().contains("should-not-appear"))

        // 非法级别
        await #expect(throws: CommandExecutionError.self) {
            try await registry.execute(id: "log.level", args: ["level": "verbose"])
        }
    }

    @Test func backendListAndStatusOffline() async throws {
        let (registry, _) = try makeRegistry("backend")
        let list = try await registry.execute(id: "backend.list")
        #expect(list.ok)
        #expect(list.text.contains("Ollama"))
        #expect(list.text.contains("ComfyUI"))
        #expect(list.text.contains("未启用"))

        // 全禁用 → 探测零网络、秒回
        let status = try await registry.execute(id: "backend.status")
        #expect(status.ok)
        #expect(status.text.contains("未启用"))
        #expect(!status.text.contains("在线"))
    }

    @Test func sessionNewAndList() async throws {
        let (registry, deps) = try makeRegistry("sessioncmd")
        let created = try await registry.execute(id: "session.new")
        #expect(created.ok)
        let id = created.text.replacingOccurrences(of: "已创建会话：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(deps.sessions?.loadSession(id: id) != nil)

        let list = try await registry.execute(id: "session.list")
        #expect(list.ok)
        #expect(list.text.contains("会话（1 个）"))
    }

    @Test func memoryAddAndList() async throws {
        let (registry, deps) = try makeRegistry("memcmd")
        let consumer = try #require(deps.memoryProposalConsumer)
        _ = try consumer.grantCandidateSubmission(
            sourceID: "preset-command",
            reason: "memory.add command test explicit candidate submission grant"
        )
        let added = try await registry.execute(id: "memory.add", args: ["text": "用户喜欢晴天"])
        #expect(added.ok)
        #expect(try deps.memory?.searchFacts(keyword: "晴天").count == 1)
        #expect(try deps.memory?.facts().first?.memoryScope == MemoryScope(
            sessionID: "test-session",
            projectID: "test-project"
        ))

        let list = try await registry.execute(id: "memory.list")
        #expect(list.ok)
        #expect(list.text.contains("用户喜欢晴天"))
    }

    @Test func memoryAddFailsClosedWithoutActiveScopeConsumer() async throws {
        let (_, deps) = try makeRegistry("memcmd-no-scope")
        var noScopeDeps = deps
        noScopeDeps.memoryScopeProvider = nil
        let noScopeRegistry = CommandRegistry(commands: PresetCommands.all(dependencies: noScopeDeps))

        let result = try await noScopeRegistry.execute(
            id: "memory.add",
            args: ["text": "不应写入"]
        )
        #expect(!result.ok)
        #expect(try deps.memory?.facts().isEmpty == true)
    }

    @Test func workflowRunWithMockProvider() async throws {
        let (registry, deps) = try makeRegistry("workflow", withProvider: MockWorkflowProvider())
        // 存一个最小自定义模板
        let template = WorkflowTemplate(
            id: "t1", name: "测试模板", description: "d",
            steps: [
                WorkflowStep(id: "s1", type: .custom, title: "步骤一",
                             promptTemplate: "{{input}}", inputs: ["input"], outputKey: "out"),
            ],
            requiredInputs: ["input"]
        )
        try deps.workflows.saveTemplate(template)

        let result = try await registry.execute(
            id: "workflow.run",
            args: ["name": "t1", "input": "hello"],
            confirmation: true
        )
        #expect(result.ok)
        #expect(result.text.contains("测试模板"))
        #expect(result.text.contains("执行 1 步"))
    }

    @Test func workflowRunRequiresProvider() async throws {
        let (registry, _) = try makeRegistry("workflow-noprovider")
        let result = try await registry.execute(
            id: "workflow.run",
            args: ["name": "manju-full"],
            confirmation: true
        )
        #expect(!result.ok)
        #expect(result.text.contains("LLM 提供者"))
    }

    @Test func confirmationRequired() async throws {
        let (registry, _) = try makeRegistry("confirm")
        await #expect(throws: CommandExecutionError.confirmationRequired("settings.reset")) {
            try await registry.execute(id: "settings.reset")
        }
        // confirmation=true 放行
        let ok = try await registry.execute(id: "settings.reset", confirmation: true)
        #expect(ok.ok)
        // 无需确认的命令不受影响
        let open = try await registry.execute(id: "settings.open")
        #expect(open.ok)
    }

    @Test func unknownAndMissingArgument() async throws {
        let (registry, _) = try makeRegistry("errors")
        await #expect(throws: CommandExecutionError.unknownCommand("nope.x")) {
            try await registry.execute(id: "nope.x")
        }
        await #expect(throws: CommandExecutionError.self) {
            try await registry.execute(id: "env.delete")
        }
    }

    @Test func disabledCommandFailsClosedAndPendingRecoveryExplainsState() async throws {
        let registry = CommandRegistry(commands: [
            CommandDefinition(
                id: "provider.reconnect",
                title: "重新连接提供商",
                category: .backend,
                availability: { .disabled(reason: "提供商授权已失效") }
            ) { _ in .success("must not execute") },
        ])
        await #expect(throws: CommandExecutionError.disabled(
            commandID: "provider.reconnect", reason: "提供商授权已失效"
        )) {
            try await registry.execute(id: "provider.reconnect")
        }

        let parsed = CommandParser().parse("/provider.reconnect", registry: registry)
        let pending = try #require(registry.makePendingRequest(for: parsed))
        #expect(registry.recoverPendingRequest(pending) == .disabled(reason: "提供商授权已失效"))
    }
}

// MARK: - Parser

struct CommandParserTests {

    private let parser = CommandParser()

    @Test func structuredIdForms() throws {
        let (registry, _) = try makeRegistry("parser-struct")
        for input in ["env.list", "/env.list", "env list"] {
            let parsed = parser.parse(input, registry: registry)
            #expect(parsed.command?.id == "env.list", "输入 \(input) 未命中 env.list")
            #expect(parsed.matched)
        }
        // 结构化 + 参数
        let withArgs = parser.parse("env.set OPENAI_API_KEY=sk-abc123", registry: registry)
        #expect(withArgs.command?.id == "env.set")
        #expect(withArgs.args["name"] == "OPENAI_API_KEY")
        #expect(withArgs.args["value"] == "sk-abc123")
    }

    @Test func naturalLanguageLogLevel() throws {
        let (registry, _) = try makeRegistry("parser-nl")
        let parsed = parser.parse("设置日志级别为 debug", registry: registry)
        #expect(parsed.command?.id == "log.level")
        #expect(parsed.args["level"] == "debug")
        // 中文级别词 → 归一化
        let zh = parser.parse("把日志等级改成错误", registry: registry)
        #expect(zh.command?.id == "log.level")
        #expect(zh.args["level"] == "error")
    }

    @Test func naturalLanguageEnvSet() throws {
        let (registry, _) = try makeRegistry("parser-envset")
        let parsed = parser.parse("设置 OPENAI_API_KEY 为 sk-test-123", registry: registry)
        #expect(parsed.command?.id == "env.set")
        #expect(parsed.args["name"] == "OPENAI_API_KEY")
        #expect(parsed.args["value"] == "sk-test-123")
    }

    @Test func naturalLanguageOthers() throws {
        let (registry, _) = try makeRegistry("parser-others")
        #expect(parser.parse("列出所有环境变量", registry: registry).command?.id == "env.list")
        #expect(parser.parse("删除环境变量 API_KEY", registry: registry).command?.id == "env.delete")
        #expect(parser.parse("新建会话", registry: registry).command?.id == "session.new")
        #expect(parser.parse("记住用户喜欢晴天", registry: registry).command?.id == "memory.add")
        #expect(parser.parse("运行工作流 manju-full", registry: registry).command?.id == "workflow.run")
        #expect(parser.parse("打开设置面板", registry: registry).command?.id == "settings.open")
    }

    @Test func memoryAddTextStripsVerb() throws {
        let (registry, _) = try makeRegistry("parser-mem")
        let parsed = parser.parse("记住用户喜欢晴天", registry: registry)
        #expect(parsed.args["text"] == "用户喜欢晴天")
    }

    @Test func noMatchReturnsSuggestions() throws {
        let (registry, _) = try makeRegistry("parser-nomatch")
        let parsed = parser.parse("今天天气不错", registry: registry)
        #expect(!parsed.matched)
        #expect(!parsed.suggestions.isEmpty)
        // help 返回全部
        let help = parser.parse("help", registry: registry)
        #expect(help.suggestions.count == registry.count)
    }

    @Test func ambiguousKeywordFallsBackToCustomParse() throws {
        let (registry, _) = try makeRegistry("parser-tie")
        // "设置" 同时命中 env.set / settings.open；env.set 能提取参数 → 胜出
        let parsed = parser.parse("设置 MY_FLAG 为 on", registry: registry)
        #expect(parsed.command?.id == "env.set")
        #expect(parsed.args["name"] == "MY_FLAG")
        #expect(parsed.args["value"] == "on")
    }

    @Test func composerSlashCommandsUseOneCanonicalIdentityAcrossChineseAndEnglish() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()

        let aliases: [(String, String)] = [
            ("/compact", "compact"),
            ("/压缩", "compact"),
            ("/help", "help"),
            ("/帮助", "help"),
            ("/status", "status"),
            ("/状态", "status"),
            ("/tasks", "tasks"),
            ("/任务", "tasks"),
            ("/model", "model"),
            ("/模型", "model"),
        ]

        for (input, expectedID) in aliases {
            let parsed = parser.parse(input, registry: registry)
            #expect(parsed.command?.id == expectedID, "输入 \(input) 应解析为 \(expectedID)")
            #expect(parsed.disposition == .command)
        }
    }

    @Test func slashCompletionSupportsSelectionKeysAndDismissal() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        var completion = parser.completionState(for: "/", registry: registry)

        // W5-050 retarget of the W5-041 WRITE_SET_ESCALATION (expectation-only).
        // registerComposerCommands() now installs the full Phase 3 vocabulary,
        // so completionState("/") returns all 34 approved N05/N11 rows in registry
        // order instead of the pre-registration 5-ID subset. The keyboard
        // selection contract is unchanged and stays pinned, only widened:
        //  - the empty-prefix list is the exact 34-ID catalog order (== the
        //    ComposerCommandCatalogRegistrationTests `expectedComposerVocabulary`
        //    and the App phaseThreeCatalog order — single source of truth),
        //  - down/up clamp within the list, tab/enter accept ONLY the currently
        //    selected row's identity, and escape dismisses.
        // This test asserts nothing about dispatch/execution; unregistered IDs
        // still parse to nil and refuse direct execution, which stays pinned by
        // composerCommandsOnlyCreatePendingRequests above and
        // ComposerCommandCatalogRegistrationTests.unregisteredCommandsStayUnroutable /
        // registeredComposerCommandsStillRefuseDirectExecution. No assertion is
        // removed and no gate is relaxed.
        #expect(completion.suggestions.map(\.id) == [
            "help", "commands", "boundary", "boundary.set", "add-dir", "status", "copy", "tasks",
            "stop", "compact", "retry", "canvas.run", "canvas.cancel",
            "canvas.minimap", "provider", "provider.use", "model", "workflow",
            "approve", "reject", "memory", "memory.propose", "skills", "permissions", "mcp",
            "context", "clear", "rewind", "doctor", "usage", "export", "rename", "resume", "plan", "shortcuts",
        ])
        #expect(completion.selected?.id == "help")

        #expect(completion.handle(.down) == .moveSelection(index: 1))
        #expect(completion.selected?.id == "commands")
        #expect(completion.handle(.up) == .moveSelection(index: 0))
        #expect(completion.selected?.id == "help")
        #expect(completion.handle(.tab) == .accept(commandID: "help"))
        #expect(completion.handle(.enter) == .accept(commandID: "help"))
        #expect(completion.handle(.escape) == .dismiss)
    }

    @Test func urlAndCodeAreMessagesNotCommands() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()

        for input in [
            "https://example.com/compact",
            "let compact = true",
            "```swift\nlet status = model\n```",
            "https://example.com\n请解释这段代码",
        ] {
            let parsed = parser.parse(input, registry: registry)
            #expect(parsed.command == nil, "不应拦截 \(input)")
            #expect(parsed.disposition == .message)
        }
    }

    @Test func composerCommandsOnlyCreatePendingRequests() throws {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        for (input, requiresApproval) in [("/compact", true), ("/压缩", true), ("/model", false), ("/模型", false)] {
            let parsed = parser.parse(input, registry: registry)
            let pending = try #require(
                registry.makePendingRequest(for: parsed, requestID: requestID)
            )
            #expect(pending.id == requestID)
            #expect(pending.requiresPolicyApproval == requiresApproval)
        }

        let help = parser.parse("/帮助", registry: registry)
        let helpRequest = try #require(registry.makePendingRequest(for: help, requestID: requestID))
        #expect(!helpRequest.requiresPolicyApproval)
    }
}
