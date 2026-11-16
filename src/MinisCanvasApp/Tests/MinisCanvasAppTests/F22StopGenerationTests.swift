import Testing
import os
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - F22⑦ stopGeneration 闭环测试
//
// 链路：停止按钮 → ChatStore.stopStreaming()（ChatStore.swift:902）
//   1) agentEngine.interrupt()          —— 引擎迭代边界中断
//   2) onStreamingStopped?()            —— BridgeStore.swift:362 装配 →
//      ApprovalPromptCenter.stopGeneration()（ApprovalPromptCenter.swift:58）
//      → resolve(approved: false, reason: "生成已停止")：挂起审批按拒绝恢复
//   3) streamingTask?.cancel() + isStreaming=false + 气泡「已中断」
//
// 本文件覆盖：
//   A. 生成中调用 stop → 状态闭环：
//      · 不再吐字（停止后消息内容冻结，打字机缓冲不再追加）
//      · 状态标记 stopped（isStreaming=false、气泡 isStreaming=false、「已中断」提示）
//      · 挂起审批被 stopGeneration 按拒绝恢复（approved=false, reason="生成已停止"）
//      · 生产装配链路（BridgeStore.attachProductionServices）下同样闭环
//   B. 未生成时调用 stop 无副作用：
//      · ChatStore 空闲时 stopStreaming：不追加提示、消息不变、保持空闲
//      · ApprovalPromptCenter 无挂起请求时 stopGeneration：纯 no-op，可重复调用
//
// 复用 C4_1InterruptWiringTests.swift 的 InterruptRecordingEngine（同测试 target，
// internal 可见）：先吐「部分输出」再挂起，模拟「生成进行中」。

@Suite("F22⑦ stopGeneration 闭环")
@MainActor
struct F22StopGenerationTests {

    // MARK: A1 审批中心单元层：挂起审批被 stopGeneration 按拒绝恢复

    @Test func stopGenerationResolvesPendingApprovalAsDenied() async throws {
        let center = ApprovalPromptCenter()
        let request = ApprovalRequest(
            id: "call_f22",
            toolName: "shell_execute",
            inputSummary: "command: echo hi",
            riskLevel: .high,
            requiresApproval: true
        )

        // 模拟 AgentLoop 挂起等待用户裁决
        let decisionTask = Task { @MainActor in await center.present(request) }

        var waited: TimeInterval = 0
        while center.pendingRequest == nil && waited < 2 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        #expect(center.pendingRequest != nil, "审批请求应处于挂起状态")

        // 生成停止 → 挂起审批必须按拒绝恢复（防「停止后再点允许」）
        center.stopGeneration()

        let decision = await decisionTask.value
        #expect(decision.approved == false, "stopGeneration 后挂起审批应被拒绝")
        #expect(decision.reason == "生成已停止")
        #expect(center.pendingRequest == nil, "弹窗状态应清空（状态闭环）")
    }

    // MARK: A2 聊天流层：生成中 stop → 不再吐字 + 状态标记 stopped

    @Test func stopDuringStreamingFreezesOutputAndMarksStopped() async throws {
        let chat = ChatStore()
        let mock = InterruptRecordingEngine()
        chat.agentEngine = mock
        let sessionID = try #require(chat.activeSessionID)

        chat.draftText = "F22 生成中停止"
        chat.sendDraft()
        #expect(chat.isStreaming, "发送后应进入生成中状态")
        let firstExecutionIdentity = try #require(
            chat.activeExecutionIdentity(for: sessionID)
        )

        // 等首段输出上屏（打字机 3 字/16ms），确认「生成中」有实际吐字
        var waited: TimeInterval = 0
        while !(chat.messages.last?.content.contains("部分输出") ?? false) && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(chat.messages.last?.content.contains("部分输出") == true)

        chat.stopStreaming()

        // 1) 状态标记 stopped：全局/气泡双复位 + 「已中断」提示 + 已输出保留
        #expect(chat.isStreaming == false, "isStreaming 应复位（按钮切回发送态）")
        #expect(chat.messages.last?.isStreaming == false, "流式气泡应收尾")
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.wasInterrupted == true)
        #expect(chat.messages.last?.content.contains("部分输出") == true, "已输出保留")

        // 2) 不再吐字：停止后内容冻结（MainActor 串行，打字机循环随 Task 取消而停）
        let frozen = chat.messages.last?.content
        try await Task.sleep(for: .milliseconds(150))
        #expect(chat.messages.last?.content == frozen, "停止后不得继续吐字")
        #expect(chat.isStreaming == false, "停止后不得被残留流任务重新置位")

        // A terminal callback from the cancelled turn must not settle the
        // session after stop retired its canonical execution identity.
        #expect(
            chat.markExecutionFailed(
                sessionID: sessionID,
                executionIdentity: firstExecutionIdentity,
                reason: "late failure"
            ) == false
        )
        #expect(
            chat.markExecutionSucceeded(
                sessionID: sessionID,
                executionIdentity: firstExecutionIdentity
            ) == false
        )
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .idle)
    }

    // MARK: A3 接线层：stopStreaming 经 onStreamingStopped 触发审批中心 stopGeneration

    @Test func stopStreamingDeniesPendingApprovalViaWiring() async throws {
        let chat = ChatStore()
        chat.agentEngine = InterruptRecordingEngine()
        let center = ApprovalPromptCenter()
        // 与 BridgeStore.attachProductionServices（BridgeStore.swift:362-364）同款装配
        chat.onStreamingStopped = { center.stopGeneration() }

        // 审批弹窗挂起（模拟工具调用等待裁决期间用户按停止）
        let decisionTask = Task { @MainActor in
            await center.present(ApprovalRequest(
                id: "call_wiring",
                toolName: "file_write",
                inputSummary: "path: /tmp/x",
                riskLevel: .high,
                requiresApproval: true
            ))
        }
        var waited: TimeInterval = 0
        while center.pendingRequest == nil && waited < 2 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        #expect(center.pendingRequest != nil)

        chat.draftText = "接线测试"
        chat.sendDraft()
        #expect(chat.isStreaming)

        let originalAssistant = try #require(chat.messages.last)
        #expect(originalAssistant.role == .assistant)
        chat.stopStreaming()

        let decision = await decisionTask.value
        #expect(decision.approved == false, "停止后挂起审批应经接线路径被拒绝")
        #expect(decision.reason == "生成已停止")
        #expect(center.pendingRequest == nil)
        #expect(chat.isStreaming == false)
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.wasInterrupted == true)
        #expect(chat.messages.last?.id == originalAssistant.id)
        #expect(chat.messages.last?.content == originalAssistant.content)
        try await Task.sleep(for: .milliseconds(150))
        #expect(chat.messages.last?.content == originalAssistant.content)
    }

    // MARK: A4 生产装配链路：BridgeStore.attachProductionServices 下同样闭环

    @Test func productionWiringStopsPendingApproval() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("f22-real-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        // Reuse the existing productionCompositionScopesDurableTurnContext
        // synthetic readiness fixture. It is explicitly Mock, never live API
        // evidence; production route validation still consumes its own receipt.
        let readiness = ProviderReadinessStore(directory: sessionDirectory)
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "F22Approval788", modelID: "f22-788", status: .passed,
            readinessState: .mock, checkedAt: Date(), evidenceID: "f22-788-mock-readiness",
            isApplied: true, discoveryReceiptID: "f22-788-mock-discovery", discoveredAt: Date(),
            applyReceiptID: "provider-readiness-apply:f22-788-mock", appliedAt: Date()
        )]))
        let bridge = BridgeStore(canvasRuntimeState: .disabled, providerReadinessStore: readiness,
                                 canvasFeatureLane: .phase3NonCanvas)
        let center = bridge.approvalCenter
        let decisions = OSAllocatedUnfairLock<ApprovalDecision?>(initialState: nil)
        let recorder = F22RecordingApprovalDelegate788(
            base: ApprovalPromptDelegate(center: center), decisions: decisions
        )
        bridge.attachProductionServices(
            fileAccessAllowedRoot: sessionDirectory,
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(fileURL: sessionDirectory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: sessionDirectory.appendingPathComponent("skills")),
            approvalDelegateOverride: recorder,
            policyDefaults: ProductionPolicyDefaults(autonomyLevel: .l2),
            canvasRuntimeState: .disabled,
            externalRunners: [:],
            // This existing route requires transport capability for a nonbuilt-in
            // Provider. The injected FIFO below has no URLSession/network code.
            externalNetworkAllowed: true,
            sessionReadSecretStore: EnvVarStore(directory: sessionDirectory.appendingPathComponent("env"))
        )
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        let target = sessionDirectory.appendingPathComponent("f22-never-written.txt")
        let provider = F22ApprovalProvider788(target: target)
        bridge.chat.streamingProviderOverride = provider
        let sessionID = try #require(bridge.chat.activeSessionID)
        bridge.chat.draftText = "生产装配测试"
        bridge.chat.sendDraft()
        #expect(bridge.chat.isStreaming)
        var waited: TimeInterval = 0
        while center.pendingRequest == nil && waited < 3 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        guard let request = center.pendingRequest else {
            Issue.record("production AgentLoop did not reach its actual ApprovalGate: \(bridge.chat.messages.map(\.content))")
            bridge.chat.stopAllStreamingForSafety()
            return
        }
        let identity = try #require(bridge.chat.activeExecutionIdentity(for: sessionID))
        // These are observed from the real producer, never constructed by the
        // test or inferred from a later UI selection. The center independently
        // validates the typed presentation context before capturing its owner.
        #expect(request.sessionID == identity.turn.sessionID)
        #expect(request.turnID == identity.turn.turnID)
        #expect(request.messageID == identity.turn.messageID)
        #expect(request.identityDigest != nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(bridge.composerApprovalReceipts.isEmpty)
        bridge.chat.stopStreaming()
        waited = 0
        while decisions.withLock({ $0 == nil }) && waited < 3 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        let decision = try #require(decisions.withLock { $0 })
        #expect(decision.approved == false, "生产装配：停止后挂起审批应被拒绝")
        #expect(decision.reason == "生成已停止")
        #expect(center.pendingRequest == nil)
        #expect(bridge.chat.isStreaming == false)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(bridge.composerApprovalReceipts.isEmpty)
        #expect(!bridge.chat.markExecutionSucceeded(sessionID: sessionID, executionIdentity: identity))
        #expect(!bridge.chat.markExecutionFailed(sessionID: sessionID, executionIdentity: identity, reason: "late"))
        let frozen = bridge.chat.messages.last?.content
        center.approvePending()
        center.confirmPending()
        try await Task.sleep(for: .milliseconds(150))
        #expect(bridge.chat.messages.last?.content == frozen)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(bridge.composerApprovalReceipts.isEmpty)
    }

    @Test func unknownManualPromptIsNotOwnedByLaterSingleStop788() async throws {
        let bridge = BridgeStore(canvasRuntimeState: .disabled, canvasFeatureLane: .phase3NonCanvas)
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("f22-stop-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        await bridge.attachProductionServices(sessionDirectory: sessionDirectory).value
        let center = bridge.approvalCenter
        // Keep the attached AgentLoop so the production task-policy gate can
        // admit this turn. Stop synchronously before MockProvider's stream runs.
        // Persistence can restore a concurrently-mutated provider selection.
        bridge.chat.streamingProviderOverride = MockProvider.shared

        let decisionTask = Task { @MainActor in
            await center.present(ApprovalRequest(
                id: "call_prod",
                toolName: "shell_execute",
                inputSummary: "command: ls",
                riskLevel: .medium,
                requiresApproval: true
            ))
        }
        var waited: TimeInterval = 0
        while center.pendingRequest == nil && waited < 2 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        #expect(center.pendingRequest != nil)

        bridge.chat.draftText = "生产装配测试"
        bridge.chat.sendDraft()
        #expect(bridge.chat.isStreaming)

        let unknownRequest = try #require(center.pendingRequest)
        #expect(unknownRequest.sessionID == nil)
        #expect(unknownRequest.turnID == nil)
        #expect(unknownRequest.attemptID == nil)
        #expect(unknownRequest.messageID == nil)
        #expect(unknownRequest.composerMode == nil)
        #expect(unknownRequest.identityDigest == nil)
        bridge.chat.stopStreaming()
        #expect(center.pendingRequest == unknownRequest,
                "a later stream cannot claim an ownerless manual prompt")
        #expect(bridge.chat.isStreaming == false)
        // Explicit global stop retains the original manual API and settles the
        // waiter without claiming that it belonged to the single stopped turn.
        center.stopGeneration()
        let decision = await decisionTask.value
        #expect(decision.approved == false, "生产装配：停止后挂起审批应被拒绝")
        #expect(decision.reason == "生成已停止")
        #expect(center.pendingRequest == nil)
        #expect(bridge.chat.isStreaming == false)
    }

    // MARK: B1 未生成时调用 stop：聊天流无副作用

    @Test func safetyKillDrainsAndSettlesEveryStreamingTask() async throws {
        let chat = ChatStore()
        chat.agentEngine = InterruptRecordingEngine()
        chat.draftText = "安全锁全量终止"
        chat.sendDraft()

        var waited: TimeInterval = 0
        while !chat.isStreaming && waited < 2 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        #expect(chat.isStreaming)

        chat.stopAllStreamingForSafety()

        #expect(chat.isStreaming == false)
        #expect(chat.hasStreamingTasksForSafety == false)
        #expect(chat.activeWritebackIdentity(for: chat.activeSessionID) == nil)
        #expect(chat.activeExecutionIdentity(for: chat.activeSessionID) == nil)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(chat.messages.last?.content.contains("已由安全锁终止") == true)
    }

    @Test func stopWhenNotStreamingHasNoSideEffects() {
        let chat = ChatStore()
        chat.agentEngine = InterruptRecordingEngine()

        let countBefore = chat.messages.count
        let contentBefore = chat.messages.last?.content

        chat.stopStreaming()

        #expect(chat.isStreaming == false, "空闲时 stop 后仍为空闲")
        #expect(chat.messages.count == countBefore, "不得新增消息")
        #expect(chat.messages.last?.content == contentBefore, "不得改动既有消息")
        #expect(chat.messages.last?.content.contains("已中断") == false, "空闲 stop 不追加提示")
    }

    // MARK: B2 未生成时调用 stop：审批中心纯 no-op（可重复调用）

    @Test func stopGenerationWithoutPendingRequestIsNoOp() {
        let center = ApprovalPromptCenter()

        // 无挂起请求：resolve 走 continuation==nil 分支，只清状态、不崩溃
        center.stopGeneration()
        center.stopGeneration()

        #expect(center.pendingRequest == nil)
    }

    // MARK: B3 未生成时调用 stop：不影响随后正常发起的审批

    @Test func stopBeforePresentDoesNotPoisonLaterApproval() async {
        let center = ApprovalPromptCenter()
        center.stopGeneration()  // 空闲时先调一次 stop

        // 之后的审批仍应正常挂起并可被用户允许
        let decisionTask = Task { @MainActor in
            await center.present(ApprovalRequest(
                id: "call_after_stop",
                toolName: "web_search",
                inputSummary: "query: x",
                riskLevel: .low,
                requiresApproval: true
            ))
        }
        var waited: TimeInterval = 0
        while center.pendingRequest == nil && waited < 2 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        #expect(center.pendingRequest != nil, "先前的空闲 stop 不应阻塞后续审批")

        center.resolve(approved: true, reason: "用户允许", confirmed: true)
        let decision = await decisionTask.value
        #expect(decision.approved == true, "后续审批应照常通过")
    }
}

/// Only the synthetic Provider is replaced. Bridge's production AgentLoop,
/// ApprovalGate, typed presentation and executor wrappers remain intact.
private final class F22ApprovalProvider788: LLMProvider, ProviderRuntimeConfigurationIdentity {
    var name: String { "F22Approval788" }
    var model = LLMModel(id: "f22-788", displayName: "F22", provider: "F22Approval788")
    var capabilities: Set<ProviderCapability> { [.tools] }
    var runtimeConfigurationMaterial: String? = "f22-788-synthetic-fifo"
    private var responses: [String]
    init(target: URL) {
        let object: [String: Any] = ["tool_calls": [["id": "call_prod", "name": "file_write",
            "input": ["path": target.path, "content": "synthetic"]]]]
        let data = try! JSONSerialization.data(withJSONObject: object)
        responses = [String(data: data, encoding: .utf8)!, "synthetic complete"]
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: responses.isEmpty ? "synthetic complete" : responses.removeFirst(),
                    stopReason: nil, usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct F22RecordingApprovalDelegate788: ApprovalDelegate {
    let base: ApprovalPromptDelegate
    let decisions: OSAllocatedUnfairLock<ApprovalDecision?>
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        let decision = await base.requestApproval(request)
        decisions.withLock { $0 = decision }
        return decision
    }
}
