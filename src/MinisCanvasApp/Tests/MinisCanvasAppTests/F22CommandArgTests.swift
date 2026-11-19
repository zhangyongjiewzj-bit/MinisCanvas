import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - F22④ 命令面板带参命令透传测试（Q8-r4 P1-3）
//
// 修复前：面板回车只把 top-1 结果 id 传给 BridgeStore.runCommand(id:)，输入里的
// 参数（`/env.set FOO=bar`）全丢 → 注册表抛 missingArgument → catch 只认
// confirmationRequired → 静默失败。
// 修复后：回车先把整条输入交给 MinisCore.CommandParser 解析，「命令 + 参数」一起
// 下发（CommandPaletteView.resolveSubmission）；runCommand 透传 args，缺参/无效/
// 未知/需确认一律写聊天流提示，不再静默。
//
// 覆盖：① 结构化（/ 前缀、双 token）与自然语言形态的参数提取
//       ② 解析未命中 → 回落 top-1（无参数）
//       ③ BridgeStore.runCommand(id:args:) 参数透传 + 错误显性化

@Suite("F22Command 带参命令透传")
@MainActor
struct F22CommandArgTests {

    // MARK: 测试装配（临时目录，绝不碰真实 Application Support）

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("F22-4-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func offlineBackends() -> LocalBackends {
        let configs: [LocalBackendKind: LocalBackendConfig] = Dictionary(
            uniqueKeysWithValues: LocalBackendKind.allCases.map {
                ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
            }
        )
        return LocalBackends(configs: configs)
    }

    private func makeRegistry(_ name: String) throws -> (CommandRegistry, CommandDependencies) {
        let dir = try makeTempDir(name)
        let deps = CommandDependencies(
            env: EnvVarStore(directory: dir),
            log: LogManager(directory: dir),
            backends: offlineBackends(),
            sessions: SessionStore(directory: dir),
            memory: MemoryStore(directory: dir),
            workflows: WorkflowStore(storeDirectory: dir.appendingPathComponent("Workflows", isDirectory: true))
        )
        return (AppCommandCatalog.makeRegistry(bridge: BridgeStore(), dependencies: deps), deps)
    }

    // MARK: ① 回车解析：结构化形态带参

    @Test func slashFormCarriesArgs() throws {
        let (registry, _) = try makeRegistry("slash")
        let submission = CommandPaletteView.resolveSubmission(
            query: "/env.set F22_KEY=hello world",
            registry: registry,
            fallbackID: nil
        )
        #expect(submission?.id == "env.set")
        #expect(submission?.args["name"] == "F22_KEY")
        #expect(submission?.args["value"] == "hello world")
    }

    /// 现场旅程 11/18：在“日志”分类里输入“设置日志”回车，解析器把它认成“设置环境变量 + 参数”，
    /// 执行了列表里看不到的命令。选了分类时只采用该分类里的命令，否则执行列表第一项。
    @Test func selectedCategoryRejectsParsedCommandFromAnotherCategory() throws {
        let (registry, _) = try makeRegistry("category")
        let unfiltered = CommandPaletteView.resolveSubmission(
            query: "设置日志", registry: registry, fallbackID: "visible.first")
        let filtered = CommandPaletteView.resolveSubmission(
            query: "设置日志", registry: registry, fallbackID: "visible.first", category: .logging)
        #expect(unfiltered?.id == "env.set")
        #expect(filtered?.id == "visible.first")
        #expect(filtered?.args.isEmpty == true)
        let sameCategory = CommandPaletteView.resolveSubmission(
            query: "env set F22_KEY=42", registry: registry, fallbackID: "visible.first", category: .environment)
        #expect(sameCategory?.id == "env.set")
    }

    @Test func twoTokenFormCarriesArgs() throws {
        let (registry, _) = try makeRegistry("twotoken")
        let submission = CommandPaletteView.resolveSubmission(
            query: "env set F22_KEY=42",
            registry: registry,
            fallbackID: nil
        )
        #expect(submission?.id == "env.set")
        #expect(submission?.args["name"] == "F22_KEY")
        #expect(submission?.args["value"] == "42")
    }

    @Test func restKindEatsWholeRemainder() throws {
        let (registry, _) = try makeRegistry("rest")
        let submission = CommandPaletteView.resolveSubmission(
            query: "/memory.add 记住 测试内容甲",
            registry: registry,
            fallbackID: nil
        )
        #expect(submission?.id == "memory.add")
        #expect(submission?.args["text"] == "测试内容甲")
    }

    @Test func bridgeMemoryCommandUsesScopedProposalConsumer() async throws {
        let dir = try makeTempDir("memory-production")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(directory: dir)
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: store,
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true))
        )
        let bridge = BridgeStore(
            memoryStore: store, memoryProposalConsumer: settings.memoryProposalConsumer
        )
        let sessionID = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(
            .init(id: "project-1", name: "Project 1", workingDirectory: dir.path),
            forSession: sessionID
        )

        // A standalone BridgeStore has no App composition owner. Without the
        // existing SettingsCenter default producer, the preset source must
        // fail closed and leave the store untouched.
        await #expect(throws: MemoryProposalConsumerError.candidateSubmissionUnauthorized) {
            try await bridge.commandRegistry.execute(
                id: "memory.add", args: ["text": "未经来源授权的记忆"]
            )
        }
        #expect(try store.facts().isEmpty)

        let defaults = try settings.provisionBuiltInMemoryCandidateSubmissions()
        let preset = SettingsCenter.BuiltInMemoryCandidateSource.presetCommand
        #expect(defaults.first(where: { $0.sourceID == preset.rawValue })?.canSubmit == true)

        let result = try await bridge.commandRegistry.execute(
            id: "memory.add",
            args: ["text": "命令入口记忆"]
        )

        #expect(result.ok)
        #expect(try store.facts().count == 1)
        #expect(try store.facts().first?.memoryScope == MemoryScope(
            sessionID: sessionID.uuidString,
            projectID: "project-1"
        ))
        #expect(try settings.memoryProposalConsumer.envelopes().first?.sourceID == preset.rawValue)

        _ = try settings.setMemoryCandidateSubmission(for: preset, enabled: false)
        await #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            try await bridge.commandRegistry.execute(
                id: "memory.add", args: ["text": "撤权后的记忆"]
            )
        }
        #expect(try store.facts().count == 1)
    }

    // MARK: ①b 回车解析：自然语言形态带参（含 customParse 决胜）

    @Test func naturalLanguageFormCarriesArgs() throws {
        let (registry, _) = try makeRegistry("nl")
        // 「设置」同时命中 env.set 与 settings.open（同分）→ customParse 预检决胜
        let submission = CommandPaletteView.resolveSubmission(
            query: "设置 F22_KEY 为 99",
            registry: registry,
            fallbackID: nil
        )
        #expect(submission?.id == "env.set")
        #expect(submission?.args["name"] == "F22_KEY")
        #expect(submission?.args["value"] == "99")
    }

    // MARK: ② 解析未命中 → 回落 top-1（无参数）

    @Test func unmatchedQueryFallsBackToTopResult() throws {
        let (registry, _) = try makeRegistry("fallback")
        let unmatchedQuery = "qzxv-rjpl-847291"
        let parsed = MinisCore.CommandParser().parse(unmatchedQuery, registry: registry)
        #expect(parsed.command == nil && parsed.matchScore == 0)
        let submission = CommandPaletteView.resolveSubmission(
            query: unmatchedQuery,
            registry: registry,
            fallbackID: "env.list"
        )
        #expect(submission?.id == "env.list")
        #expect(submission?.args.isEmpty == true)
        // 空输入同理：直接回落
        let empty = CommandPaletteView.resolveSubmission(
            query: "   ",
            registry: registry,
            fallbackID: "env.list"
        )
        #expect(empty?.id == "env.list")
        #expect(empty?.args.isEmpty == true)
        // 无回落目标且未命中 → nil（回车什么都不做）
        let none = CommandPaletteView.resolveSubmission(
            query: unmatchedQuery,
            registry: registry,
            fallbackID: nil
        )
        #expect(none == nil)
    }

    // MARK: ③ BridgeStore.runCommand：参数透传 + 错误显性化

    /// 线程安全的参数捕获盒（测试断言用）。
    private final class CapturedArgs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: String] = [:]
        var args: [String: String] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func set(_ value: [String: String]) {
            lock.lock(); stored = value; lock.unlock()
        }
    }

    @Test func runCommandForwardsArgsToExecutor() async throws {
        let bridge = BridgeStore()
        let captured = CapturedArgs()
        bridge.commandRegistry.register(CommandDefinition(
            id: "f22.arg.echo",
            title: "F22 参数回显",
            category: .environment,
            argumentSpecs: [CommandArgumentSpec(name: "value", label: "值")]
        ) { args in
            captured.set(args)
            return .success("已收到 \(args["value"] ?? "")")
        })
        bridge.runCommand(id: "f22.arg.echo", args: ["value": "42"])
        for _ in 0..<100
        where !bridge.chat.messages.contains(where: { $0.content.contains("已收到 42") }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(captured.args["value"] == "42", "runCommand 应把参数完整透传给命令执行体")
        #expect(bridge.chat.messages.contains { $0.content.contains("已收到 42") })
        #expect(bridge.isCommandPalettePresented == false, "执行成功 → 面板关闭")
    }

    @Test func runCommandMissingArgSurfacesErrorInsteadOfSilence() async throws {
        let bridge = BridgeStore()
        bridge.commandRegistry.register(CommandDefinition(
            id: "f22.arg.required",
            title: "F22 必填参数",
            category: .environment,
            argumentSpecs: [CommandArgumentSpec(name: "value", label: "值")]
        ) { _ in .success("不应执行到") })
        bridge.isCommandPalettePresented = true
        bridge.runCommand(id: "f22.arg.required", args: [:])
        for _ in 0..<100
        where !bridge.chat.messages.contains(where: { $0.content.contains("缺少参数") }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(bridge.chat.messages.contains { $0.content.contains("缺少参数") },
                "缺参错误必须写聊天流提示，不再静默")
        #expect(!bridge.chat.messages.contains { $0.content.contains("不应执行到") })
        #expect(bridge.isCommandPalettePresented == true, "失败时面板保持打开供补参重试")
    }

    @Test func runCommandUnknownAndConfirmationSurfaceErrors() async throws {
        let bridge = BridgeStore()
        bridge.runCommand(id: "f22.no.such.command")
        for _ in 0..<100
        where !bridge.chat.messages.contains(where: { $0.content.contains("未知命令") }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(bridge.chat.messages.contains { $0.content.contains("未知命令") })

        bridge.commandRegistry.register(CommandDefinition(
            id: "f22.arg.confirm",
            title: "F22 需确认",
            category: .environment,
            requiresConfirmation: true
        ) { _ in .success("不应执行到") })
        bridge.runCommand(id: "f22.arg.confirm")
        for _ in 0..<100
        where !bridge.chat.messages.contains(where: { $0.content.contains("需要确认") }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(bridge.chat.messages.contains { $0.content.contains("需要确认") })
    }

    // MARK: ④ 端到端：面板解析出的参数直接灌进 runCommand（临时目录存储）

    @Test func parsedSubmissionEndToEndWritesEnvStore() async throws {
        let (registry, deps) = try makeRegistry("e2e")
        let submission = CommandPaletteView.resolveSubmission(
            query: "/env.set F22_E2E_KEY=端到端值",
            registry: registry,
            fallbackID: nil
        )
        #expect(submission != nil)
        guard let submission else { return }
        let result = try await registry.execute(id: submission.id, args: submission.args)
        #expect(result.ok)
        #expect(result.text.contains("F22_E2E_KEY"))
        #expect(deps.env.getEnvVar(name: "F22_E2E_KEY") == "端到端值",
                "面板解析出的参数应真正写入存储（修复前参数丢失 → missingArgument 静默失败）")
    }
}
