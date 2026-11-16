import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - E10 工作流接入聊天

/// 指定第 N 次 sendMessage 抛错的 LLMProvider（测试断点续跑用）。
final class FailingLLMProvider: LLMProvider, @unchecked Sendable {
    let failOnCall: Int
    private let lock = NSLock()
    private var calls = 0

    init(failOnCall: Int) { self.failOnCall = failOnCall }

    var name: String { "Failing" }
    var model = LLMModel(id: "fail", displayName: "Failing", provider: "Test")

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        let n = nextCall()
        if n == failOnCall {
            throw NSError(domain: "WorkflowChatTests", code: n,
                          userInfo: [NSLocalizedDescriptionKey: "模拟失败"])
        }
        return LLMResponse(text: "第 \(n) 步输出", stopReason: "end_turn",
                           usage: LLMUsage(inputTokens: 0, outputTokens: 0))
    }

    /// 取下一个调用序号（同步方法内加锁，避免 async 上下文的 NSLock 限制）。
    private func nextCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(domain: "WorkflowChatTests", code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey: "未使用"]))
        }
    }
}

/// 忽略 Task cancellation，直到测试显式放行；用于验证控制器不会迟到写回。
final class CancellationIgnoringLLMProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LLMResponse, Never>?
    private var released = false
    private var started = false

    var name: String { "CancellationIgnoring" }
    var model = LLMModel(id: "cancel-ignoring", displayName: "Cancellation Ignoring", provider: "Test")

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        await withCheckedContinuation { continuation in
            lock.lock()
            started = true
            if released {
                lock.unlock()
                continuation.resume(returning: Self.response)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: Self.response)
    }

    private static var response: LLMResponse {
        LLMResponse(text: "迟到输出", stopReason: "end_turn",
                    usage: LLMUsage(inputTokens: 0, outputTokens: 0))
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CancellationError())
        }
    }
}

private actor HeldWorkflowProviderPreparation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func isPending() -> Bool { continuation != nil }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("工作流接入聊天（E10）")
@MainActor
struct WorkflowChatTests {

    @Test func selectedProviderPreparationDoesNotBlockActorAndRejectsChangedModel() async throws {
        let chat = ChatStore()
        let controller = WorkflowChatController()
        let gate = HeldWorkflowProviderPreparation()
        chat.selectedCustomProvider = EnvVarEntry(
            name: "SYNTHETIC_WORKFLOW_PERF06", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid", modelNames: ["model-a", "model-b"],
            protocolType: .openaiCompatible
        )
        chat.selectedModelID = "model-a"
        chat.providerConstructionPauseForTests = { await gate.wait() }

        controller.run(text: "/workflow 小说拆解 novel=合成内容", chat: chat)
        #expect(controller.isRunning)
        #expect(chat.messages.last?.content.contains("开始执行工作流") == true)
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.isPending()) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await gate.isPending()
        #expect(pending, "Provider construction must reach the detached worker")
        chat.selectedModelID = "model-b"
        await gate.release()
        await waitForWorkflow(controller)

        #expect(!controller.isRunning)
        #expect(chat.messages.contains { $0.content.contains("无法创建 LLM Provider") })
        #expect(!chat.messages.contains { $0.content.contains("工作流执行中") })
        #expect(!chat.messages.contains { $0.content.contains("执行完成") })
        #expect(controller.sharedRunner.completedOutputs(templateID: "manju-novel-breakdown").isEmpty)
    }

    @Test func cancelledProviderPreparationCannotStartWorkflowOrWriteLateResult() async throws {
        let chat = ChatStore()
        let controller = WorkflowChatController()
        let gate = HeldWorkflowProviderPreparation()
        chat.selectedCustomProvider = EnvVarEntry(
            name: "SYNTHETIC_WORKFLOW_CANCEL_PERF06", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid", modelNames: ["model-a"],
            protocolType: .openaiCompatible
        )
        chat.selectedModelID = "model-a"
        chat.providerConstructionPauseForTests = { await gate.wait() }

        controller.run(text: "/workflow 小说拆解 novel=合成内容", chat: chat)
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.isPending()) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await gate.isPending()
        #expect(pending)
        controller.cancel()
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(!controller.isRunning)
        #expect(chat.messages.contains { $0.content.contains("开始执行工作流") })
        #expect(!chat.messages.contains { $0.content.contains("执行完成") })
        #expect(!chat.messages.contains { $0.content.contains("无法创建 LLM Provider") })
        #expect(controller.sharedRunner.completedOutputs(templateID: "manju-novel-breakdown").isEmpty)
    }

    /// 轮询等待工作流执行结束（让出 MainActor 时间片给执行 Task）。
    private func waitForWorkflow(_ controller: WorkflowChatController) async {
        for _ in 0..<400 {
            if !controller.isRunning { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func triggerDetection() {
        #expect(WorkflowChatController.isWorkflowTrigger("/workflow 漫剧全流程"))
        #expect(WorkflowChatController.isWorkflowTrigger("运行工作流 漫剧全流程"))
        #expect(WorkflowChatController.isWorkflowTrigger("/workflow"))
        #expect(!WorkflowChatController.isWorkflowTrigger("你好"))
        #expect(!WorkflowChatController.isWorkflowTrigger("运行 画布"))
        #expect(!WorkflowChatController.isWorkflowTrigger("执行"))
    }

    @Test func parseRequest() {
        let req = WorkflowChatController.parse("/workflow 漫剧全流程")
        #expect(req?.templateName == "漫剧全流程")
        #expect(req?.inputs.isEmpty == true)
        #expect(req?.leftover == nil)

        let req2 = WorkflowChatController.parse("运行工作流 漫剧全流程 novel=从前有个修仙少年")
        #expect(req2?.templateName == "漫剧全流程")
        #expect(req2?.inputs["novel"] == "从前有个修仙少年")

        // 无 key=value 时剩余文本作为兜底输入
        let req3 = WorkflowChatController.parse("/workflow 漫剧全流程 从前有个修仙少年")
        #expect(req3?.templateName == "漫剧全流程")
        #expect(req3?.leftover == "从前有个修仙少年")

        // 无模板名 → nil
        #expect(WorkflowChatController.parse("/workflow") == nil)
    }

    // MARK: F15 P2-4 key=value 值支持空格 / 引号 / 多行全文

    @Test func parseValueWithSpacesKeptWhole() {
        // 修复前：按空白切 token，novel=长 文本 只取「长」，其余静默丢弃
        let req = WorkflowChatController.parse("/workflow 漫剧全流程 novel=长 文本 还有 更多 内容")
        #expect(req?.templateName == "漫剧全流程")
        #expect(req?.inputs["novel"] == "长 文本 还有 更多 内容")
        #expect(req?.leftover == nil)
    }

    @Test func parseMultipleKeyValuesOnSeparateLines() {
        let req = WorkflowChatController.parse("/workflow 漫剧全流程 novel=第一章 少年 醒来\nstyle=热血 少年漫")
        #expect(req?.inputs["novel"] == "第一章 少年 醒来")
        #expect(req?.inputs["style"] == "热血 少年漫")
        #expect(req?.leftover == nil)
    }

    @Test func parseQuotedValueAndTrailingKey() {
        // 引号包裹：值内可含 =，闭合后继续解析后续 key=value
        let req = WorkflowChatController.parse("/workflow 小说拆解 novel=\"第一 章：主角=路人\" style=轻松")
        #expect(req?.inputs["novel"] == "第一 章：主角=路人")
        #expect(req?.inputs["style"] == "轻松")
    }

    @Test func parseMultilineTextGoesToLeftover() {
        // 无 key= 的多行文本 → 全文模式 leftover（兜底到第一个缺失的必填输入）
        let text = "/workflow 漫剧全流程 从前有个少年\n第二行 继续\n第三行"
        let req = WorkflowChatController.parse(text)
        #expect(req?.inputs.isEmpty == true)
        #expect(req?.leftover == "从前有个少年\n第二行 继续\n第三行")
    }

    @Test func bridgeRoutesWorkflowTrigger() async throws {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        // 走真实路由：chat.onSendCommand → BridgeStore.handleChatCommand → 工作流执行
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: bridge.chat.activeSessionID?.uuidString ?? "test-session",
            turnID: 0,
            taskID: "test-task",
            attemptID: "test-attempt",
            messageID: "test-message",
            workspaceID: bridge.chat.composerWorkspaceID,
            createdAt: Date(),
            policyRevision: "test-policy"
        )
        let handled = bridge.chat.onSendCommand?(
            "/workflow 漫剧全流程 novel=测试小说",
            snapshot
        ) ?? false
        #expect(handled)
        await awaitLegacyCanvasCommandCompletion(bridge)

        let all = bridge.chat.messages.map(\.content).joined(separator: "\n")
        // 进度消息（▶️ 开始 → ⏳ 步骤 → ✅ 完成）原地更新，最终态为完成行
        #expect(all.contains("✅ 工作流「漫剧全流程」执行完成：本次执行 7 步"))
        #expect(all.contains("**结果摘要**"))
        #expect(all.contains("剧情拆解"))
        #expect(bridge.chat.messages.contains { $0.content.hasPrefix("✅ 工作流「漫剧全流程」执行完成") })
    }

    @Test func failedWorkflowKeepsOriginHistoryAndIndependentSessionIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("story03-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let chat = ChatStore()
        defer { chat.stopAllStreamingForSafety() }
        try #require(chat.attachPersistence(sessions))
        chat.appendUser("STORY03_ORIGINAL_USER")
        chat.appendAssistant("STORY03_ORIGINAL_REPLY")
        let originID = try #require(chat.activeSessionID)
        let origin = chat.messages
        let controller = WorkflowChatController()
        defer { controller.cancel() }
        controller.providerOverride = FailingLLMProvider(failOnCall: 2)
        controller.run(text: "/workflow 漫剧全流程 novel=合成失败隔离内容", chat: chat)
        try #require(controller.isRunning)

        // No suspension before switching: the real workflow Task has not
        // executed yet, while its origin session has already been captured.
        let independentID = chat.applyNewSession(title: "STORY03 independent")
        chat.appendUser("STORY03_INDEPENDENT_USER")
        chat.appendAssistant("STORY03_INDEPENDENT_REPLY")
        let independent = chat.messages
        await waitForWorkflow(controller)
        try #require(!controller.isRunning)
        #expect(chat.activeSessionID == independentID)
        #expect(chat.messages == independent)
        let originAfter = try #require(chat.sessions.first { $0.id == originID })
        #expect(Array(originAfter.messages.prefix(origin.count)) == origin)
        #expect(originAfter.messages.count == origin.count + 1)
        #expect(originAfter.messages.last?.content.contains("❌ 工作流「漫剧全流程」执行失败") == true)
        #expect(originAfter.messages.last?.content.contains("已完成 1/7 步") == true)
        #expect(!originAfter.messages.contains { $0.content.contains("**结果摘要**") })

        let cold = SessionStore(directory: root)
        let savedOrigin = try #require(cold.loadSession(id: originID.uuidString))
        let savedIndependent = try #require(cold.loadSession(id: independentID.uuidString))
        #expect(savedOrigin.messages == originAfter.messages.filter { $0.role != .system }.map { $0.asLLMMessage() })
        #expect(savedIndependent.messages == independent.filter { $0.role != .system }.map { $0.asLLMMessage() })
    }

    @Test func failureShowsResumeHintAndResumes() async throws {
        let chat = ChatStore()
        let controller = WorkflowChatController()
        controller.providerOverride = FailingLLMProvider(failOnCall: 2)

        // 第一次执行：第 2 步失败 → 错误 + 断点续跑提示
        controller.run(text: "/workflow 漫剧全流程 novel=测试小说", chat: chat)
        await waitForWorkflow(controller)

        let failed = chat.messages.map(\.content).joined(separator: "\n")
        #expect(failed.contains("❌ 工作流「漫剧全流程」执行失败"))
        #expect(failed.contains("第 2/7 步"))
        #expect(failed.contains("已完成 1/7 步"))
        #expect(failed.contains("断点已保存"))

        // 换正常 Provider 重发同一条指令 → 断点续跑：第 1 步不重复执行
        controller.providerOverride = nil
        controller.run(text: "/workflow 漫剧全流程 novel=测试小说", chat: chat)
        await waitForWorkflow(controller)

        let resumed = chat.messages.map(\.content).joined(separator: "\n")
        #expect(resumed.contains("✅ 工作流「漫剧全流程」执行完成"))
        #expect(resumed.contains("本次执行 6 步"))
        #expect(resumed.contains("断点续跑 1 步"))
    }

    @Test func cancellationStopsInFlightWorkflowWithoutLateWrite() async throws {
        let chat = ChatStore()
        let controller = WorkflowChatController()
        let provider = CancellationIgnoringLLMProvider()
        controller.providerOverride = provider

        controller.run(text: "/workflow 小说拆解 novel=待取消", chat: chat)
        for _ in 0..<100 where !provider.hasStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(provider.hasStarted)

        controller.cancel()
        #expect(controller.isRunning == false)
        provider.release()
        try? await Task.sleep(for: .milliseconds(100))

        let all = chat.messages.map(\.content).joined(separator: "\n")
        #expect(all.contains("⏳ 工作流执行中"))
        #expect(!all.contains("✅ 工作流"))
        #expect(!all.contains("❌ 工作流"))
        #expect(!all.contains("结果摘要"))
    }
}

// MARK: - F15 P1-6 控制器层断点隔离 / P2-5 深链复用 runner

@Suite("F15 工作流断点隔离与深链复用")
@MainActor
struct WorkflowF15Tests {

    /// 轮询等待工作流执行结束（让出 MainActor 时间片给执行 Task）。
    private func waitForWorkflow(_ controller: WorkflowChatController) async {
        for _ in 0..<400 {
            if !controller.isRunning { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// 轮询等待聊天消息出现指定片段。
    private func waitForMessage(_ chat: ChatStore, contains fragment: String) async {
        for _ in 0..<400 {
            if chat.messages.contains(where: { $0.content.contains(fragment) }) { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func controllerCheckpointIsolatedAcrossTemplates() async {
        // 同一控制器：漫剧全流程第 2 步失败留下断点 → 换「小说拆解」重跑不得命中旧缓存
        let chat = ChatStore()
        let controller = WorkflowChatController()
        controller.providerOverride = FailingLLMProvider(failOnCall: 2)

        controller.run(text: "/workflow 漫剧全流程 novel=测试小说", chat: chat)
        await waitForWorkflow(controller)
        #expect(chat.messages.contains { $0.content.contains("❌ 工作流「漫剧全流程」执行失败") })

        controller.providerOverride = nil
        controller.run(text: "/workflow 小说拆解 novel=测试小说", chat: chat)
        await waitForWorkflow(controller)
        let all = chat.messages.map(\.content).joined(separator: "\n")
        // 小说拆解 4 步全部真实执行（0 步断点续跑）—— 修复前会命中漫剧全流程的缓存跳步
        #expect(all.contains("✅ 工作流「小说拆解」执行完成：本次执行 4 步"))
        #expect(!all.contains("断点续跑"))
    }

    @Test func successClearsCheckpointSoChatRerunExecutesAllSteps() async {
        let chat = ChatStore()
        let controller = WorkflowChatController()

        controller.run(text: "/workflow 小说拆解 novel=小说甲", chat: chat)
        await waitForWorkflow(controller)
        controller.run(text: "/workflow 小说拆解 novel=小说甲", chat: chat)
        await waitForWorkflow(controller)

        let all = chat.messages.map(\.content).joined(separator: "\n")
        // 两次都「本次执行 4 步」且无「断点续跑」—— 重跑 = 真正重跑
        let fullRunCount = all.components(separatedBy: "本次执行 4 步").count - 1
        #expect(fullRunCount == 2)
        #expect(!all.contains("断点续跑"))
    }

    @Test func changedInputsInvalidateControllerCheckpoint() async {
        let chat = ChatStore()
        let controller = WorkflowChatController()
        controller.providerOverride = FailingLLMProvider(failOnCall: 2)

        // 第 2 步失败留下断点（输入 小说甲）
        controller.run(text: "/workflow 小说拆解 novel=小说甲", chat: chat)
        await waitForWorkflow(controller)

        // 换输入 小说乙 重跑：旧断点作废，4 步全部重新执行
        controller.providerOverride = nil
        controller.run(text: "/workflow 小说拆解 novel=小说乙", chat: chat)
        await waitForWorkflow(controller)

        let all = chat.messages.map(\.content).joined(separator: "\n")
        #expect(all.contains("✅ 工作流「小说拆解」执行完成：本次执行 4 步"))
        #expect(!all.contains("断点续跑"))
    }

    @Test func deepLinkReusesSharedRunnerAndResumesFromCheckpoint() async throws {
        // P2-5：深链失败留下断点 → 再次深链续跑（修复前每次新建 runner，续跑失效）
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("F15Workflow-\(UUID().uuidString)", isDirectory: true)
        let store = WorkflowStore(storeDirectory: dir)
        let template = WorkflowTemplate(
            id: "f15-deep", name: "F15 深链流程", description: "test",
            steps: [
                WorkflowStep(id: "s1", type: .custom, title: "步骤一", promptTemplate: "输出 hello", outputKey: "out1"),
                WorkflowStep(id: "s2", type: .custom, title: "步骤二", promptTemplate: "再输出 {{out1}}", outputKey: "out2"),
            ],
            requiredInputs: []
        )
        try store.saveTemplate(template)
        let handler = DeepLinkHandler(bridge: bridge, workflowStore: store)

        // 第 1 次深链：第 2 步失败 → 断点保存在 sharedRunner
        bridge.workflowChat.providerOverride = FailingLLMProvider(failOnCall: 2)
        handler.handle(.runWorkflow(name: "f15-deep", input: nil))
        await waitForMessage(bridge.chat, contains: "工作流「F15 深链流程」失败")

        // 第 2 次深链：换正常 Provider → 断点续跑，1 步命中缓存（修复前为 0 步）
        bridge.workflowChat.providerOverride = nil
        handler.handle(.runWorkflow(name: "f15-deep", input: nil))
        await waitForMessage(bridge.chat, contains: "工作流「F15 深链流程」完成")
        #expect(bridge.chat.messages.contains {
            $0.content.contains("工作流「F15 深链流程」完成") && $0.content.contains("1 步命中缓存")
        })

        // 成功后断点清空：第 3 次深链全部重新执行（0 步命中缓存）
        handler.handle(.runWorkflow(name: "f15-deep", input: nil))
        await waitForMessage(bridge.chat, contains: "0 步命中缓存")
        #expect(bridge.chat.messages.contains {
            $0.content.contains("工作流「F15 深链流程」完成") && $0.content.contains("0 步命中缓存")
        })
    }

    @Test func deepLinkAndChatShareOneRunnerInstance() async throws {
        // 深链留下的断点能在聊天控制器侧看到（同一 runner 实例，断点按模板 id 隔离存放）
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("F15Workflow-\(UUID().uuidString)", isDirectory: true)
        let store = WorkflowStore(storeDirectory: dir)
        let template = WorkflowTemplate(
            id: "f15-share", name: "F15 共享流程", description: "test",
            steps: [
                WorkflowStep(id: "s1", type: .custom, title: "步骤一", promptTemplate: "输出 hello", outputKey: "out1"),
                WorkflowStep(id: "s2", type: .custom, title: "步骤二", promptTemplate: "再输出 {{out1}}", outputKey: "out2"),
            ],
            requiredInputs: []
        )
        try store.saveTemplate(template)
        let handler = DeepLinkHandler(bridge: bridge, workflowStore: store)

        bridge.workflowChat.providerOverride = FailingLLMProvider(failOnCall: 2)
        handler.handle(.runWorkflow(name: "f15-share", input: nil))
        await waitForMessage(bridge.chat, contains: "工作流「F15 共享流程」失败")

        // 聊天控制器的 sharedRunner == 深链用过的 runner：断点可见
        let controller = bridge.workflowChat
        #expect(controller.sharedRunner.completedOutputs(templateID: "f15-share")["out1"] != nil)
    }
}
