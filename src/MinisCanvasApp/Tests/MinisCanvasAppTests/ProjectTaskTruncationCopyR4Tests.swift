import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// R4 修补：无人值守的项目任务遇输出上限截断时，半截文本不会保存，
/// 失败原因不得再说“已保留部分文本，可输入继续”。状态语义不变（仍为失败）。
private final class TruncatingProjectProvider: LLMProvider, @unchecked Sendable {
    let name = "TruncatingFixture"
    var model = LLMModel(id: "truncating-fixture", displayName: "Truncating fixture", provider: "TruncatingFixture")
    var capabilities: Set<ProviderCapability> { [.tools, .streaming] }
    private let lock = NSLock()
    private var count = 0
    var sendCount: Int { lock.withLock { count } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { count += 1 }
        return LLMResponse(text: "半截项目报告", stopReason: "length", usage: LLMUsage(inputTokens: 1, outputTokens: 1))
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { count += 1 }
        return LLMResponse(text: "半截项目报告", stopReason: "length", usage: LLMUsage(inputTokens: 1, outputTokens: 1))
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("半截项目报告"))
            continuation.yield(.finished(stopReason: "length"))
            continuation.finish()
        }
    }
}

@Suite("R4 project task truncation failure copy", .serialized)
@MainActor
struct ProjectTaskTruncationCopyR4Tests {
    /// N-1：项目任务不经过 beginTurn，必须自己把已信任的项目根登记给 HookRuntime，
    /// 否则项目 hooks 对它既不执行也不 fail-closed。回退 runProjectTask 里的登记会红。
    @Test("project task registers its trusted project root with HookRuntime")
    func projectTaskRegistersTrustedRootForHooks() async throws {
        let instruction = "project hook root input"
        let fixture = try ScheduledTargetFixture(command: instruction, projectChildTarget: true)
        let project = fixture.root.appendingPathComponent("n1-project-root", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let previouslyInstalled = HookRuntime.installed
        defer {
            fixture.cleanup()
            HookRuntime.install(previouslyInstalled)
        }
        let hooks = HookRuntime(store: HookConfigStore(
            directory: fixture.root.appendingPathComponent("hook-state")), environment: { [:] })
        HookRuntime.install(hooks)
        let projectID = fixture.projectID
        fixture.chat.trustedProjectRootProvider = { scope in
            scope.projectID == projectID ? project : nil
        }
        fixture.chat.restoreSpeedTier(.fast)
        fixture.chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root),
            requestBudget: fixture.chat.budgetTracker,
            composerPolicyFacts: fixture.chat.composerPolicyFacts)
        let skills = SkillStore(skillsRoot: fixture.root.appendingPathComponent("skills"))
        fixture.chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        fixture.chat.streamingProviderOverride = TruncatingProjectProvider()
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "n1-task", parentID: "n1-parent", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "n1-task", runID: "n1-run")
        let started = fixture.chat.startProjectTask(targetID: fixture.targetID.uuidString,
            projectID: fixture.projectID, instruction: instruction, runID: "n1-run",
            taskStore: store, authorization: { true }, onFinished: {})
        try #require(started)
        let running = try #require(fixture.chat.turnTaskForTests(sessionID: fixture.targetID))
        await running.value
        let expected = project.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(hooks.knownProjectRoots().map(\.path).contains(expected))
    }

    @Test("truncated project task fails with a truthful reason and saves no partial text")
    func truncatedProjectTaskReasonIsTruthful() async throws {
        let instruction = "project truncation input"
        let fixture = try ScheduledTargetFixture(command: instruction, projectChildTarget: true)
        defer { fixture.cleanup() }
        fixture.chat.restoreSpeedTier(.fast)
        fixture.chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root),
            requestBudget: fixture.chat.budgetTracker,
            composerPolicyFacts: fixture.chat.composerPolicyFacts)
        // 生产路径要求冻结运行快照：与真实项目任务一致，由工厂在每回合给出快照。
        let skills = SkillStore(skillsRoot: fixture.root.appendingPathComponent("skills"))
        fixture.chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = TruncatingProjectProvider()
        fixture.chat.streamingProviderOverride = provider
        let store = AgentTaskStore()
        let taskID = "r4-trunc-task"
        let runID = "r4-trunc-run"
        _ = try store.enqueue(taskID: taskID, parentID: "r4-parent", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: taskID, runID: runID)
        let started = fixture.chat.startProjectTask(targetID: fixture.targetID.uuidString,
            projectID: fixture.projectID, instruction: instruction, runID: runID,
            taskStore: store, authorization: { true }, onFinished: {})
        try #require(started)
        let running = try #require(fixture.chat.turnTaskForTests(sessionID: fixture.targetID))
        await running.value

        // 夹具必须真的走到 Provider（否则不是截断路径）。
        #expect(provider.sendCount >= 1)
        let execution = try #require(fixture.chat.executionSnapshot(forSessionID: fixture.targetID))
        #expect(execution.state == .failed)
        let reason = try #require(execution.failureReason)
        #expect(reason.contains("输出上限"))
        #expect(reason.contains("未保存"))
        #expect(!reason.contains("已保留部分文本"))
        #expect(!reason.contains("输入‘继续’"))
        let receipt = try #require(store.allReceipts().first { $0.runID == runID })
        // 回执经 AgentTaskStore 脱敏为固定码（AgentTaskStore.swift:2009-2010；同 ProductionDomainIdentity3085Tests:162-165）。
        #expect(receipt.outcome == .failed(reason: "execution-failed"))
        // 半截未落会话。
        #expect(fixture.persistence.loadSession(id: fixture.targetID.uuidString)?.messages == fixture.original)
    }
}
