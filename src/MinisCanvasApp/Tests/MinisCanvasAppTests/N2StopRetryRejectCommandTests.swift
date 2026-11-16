import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// N2: /stop, /retry, /reject must run the same entry as the Stop button, the
/// failed-row Retry button and the approval card's Deny button. These tests go
/// through the real Composer path (ChatStore.submitComposer -> routeComposerSlashCommand
/// -> ComposerCommandAdjudicationCenter.evaluate) and assert the observable
/// effect of the button entries. Written RED against baseline 6906c220.
@Suite("N2 /stop /retry /reject share the button entries")
@MainActor
struct N2StopRetryRejectCommandTests {
    /// Wiring mirrors MinisCanvasApp.swift: the production desktop consumer, with
    /// /reject bound to the card's Deny entry of the given approval center.
    @discardableResult
    private func install(_ chat: ChatStore, approval: ApprovalPromptCenter? = nil) -> ComposerCommandAdjudicationCenter {
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "n2-central", leaseID: "n2-central",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l2)
        chat.configureComposerPolicy(facts)
        let desktop = N05DesktopCommandConsumer(chat: chat, openSettings: { _ in },
            openModelPicker: {}, openContext: {}, openDoctor: {},
            enterPlanMode: { chat.enterPlanMode(description: $0) },
            redactor: { ChatTranscriptRedactor(secretValues: []) })
        if let approval {
            desktop.rejectToolApproval = { snapshot in
                try N05DesktopCommandConsumer.denyPresentedToolApproval(approval, snapshot: snapshot)
            }
        }
        let center = ComposerCommandAdjudicationCenter()
        center.desktopCommandAction = { request, snapshot in try desktop.execute(request, snapshot: snapshot) }
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        return center
    }

    @Test func stopWhileGeneratingStopsTheTurnLikeTheStopButton() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let chat = ChatStore()
        install(chat)
        defer {
            entered.continuation.finish(); release.continuation.finish()
            chat.stopAllStreamingForSafety(); chat.onComposerCommandPolicy = nil
        }
        let session = try #require(chat.activeSessionID)
        chat.streamingProviderOverride = N2WaitingProvider(entered: entered.continuation, release: release.stream)
        chat.draftText = "start a real turn"
        chat.submitComposer()
        _ = try #require(chat.turnTaskForTests(sessionID: session))
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(chat.isActiveSessionGenerating)

        chat.draftText = "/stop"
        chat.submitComposer()

        // Button entry: ChatStore.stopStreaming(returnQueuedToDraft: true).
        // The command must not wait behind the turn it is meant to stop.
        #expect(!chat.isActiveSessionGenerating)
        #expect(chat.queuedComposerMessages.isEmpty)
        #expect(chat.lastComposerCommandReceipt?.commandID == "stop")
    }

    @Test func retryAfterAFailedTurnReplaysLikeTheFailedRowButton() throws {
        let chat = ChatStore()
        install(chat)
        defer { chat.stopAllStreamingForSafety(); chat.onComposerCommandPolicy = nil }
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("请重试这个请求")
        let taskStore = AgentTaskStore()
        _ = try taskStore.enqueue(taskID: "n2-retry", parentID: sessionID.uuidString,
                                  providerID: "test-provider", modelID: "test-model")
        _ = try taskStore.startRun(taskID: "n2-retry", runID: "n2-retry-run")
        _ = try taskStore.finish(runID: "n2-retry-run", outcome: .failed(reason: "provider failure"))
        chat.attachAgentTaskStore(taskStore)
        #expect(chat.sessionList.first?.indicator == .failed(reason: "execution-failed"))

        chat.draftText = "/retry"
        chat.submitComposer()

        // Button entry: ChatStore.retryFailedSession(identity) -> .running.
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .running)
        #expect(chat.lastComposerCommandReceipt?.commandID == "retry")
    }

    @Test func rejectDeniesThePresentedToolApprovalLikeTheCardButton() async throws {
        let chat = ChatStore()
        let approval = ApprovalPromptCenter()
        install(chat, approval: approval)
        defer { chat.onComposerCommandPolicy = nil }
        let sessionID = try #require(chat.activeSessionID)
        let request = ApprovalRequest(id: "n2-reject", toolName: "shell_execute",
            inputSummary: "synthetic", riskLevel: .medium, requiresApproval: true,
            sessionID: sessionID.uuidString)
        let pending = Task { await approval.present(request) }
        for _ in 0..<200 where approval.pendingRequest == nil { await Task.yield() }
        try #require(approval.pendingRequest != nil)

        chat.draftText = "/reject"
        chat.submitComposer()

        // Button entry: approval.actionsForPresentedRequest().deny().
        let decision = await pending.value
        #expect(!decision.approved)
        // Base evidence 11/9: without a /reject consumer the card only closed by
        // the 300 s expiry (test took 310 s). Require the card's own Deny reason.
        #expect(decision.reason == "用户拒绝")
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(approval.pendingRequest == nil)
        #expect(chat.lastComposerCommandReceipt?.commandID == "reject")
    }
}

@Suite("N2 /stop /retry /reject unmet conditions give one line and do nothing")
@MainActor
struct N2StopRetryRejectUnmetConditionTests {
    private func installed() -> (ChatStore, ComposerCommandAdjudicationCenter, ApprovalPromptCenter) {
        let chat = ChatStore()
        let approval = ApprovalPromptCenter()
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "n2-unmet", leaseID: "n2-unmet",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l2)
        chat.configureComposerPolicy(facts)
        let desktop = N05DesktopCommandConsumer(chat: chat, openSettings: { _ in },
            openModelPicker: {}, openContext: {}, openDoctor: {},
            enterPlanMode: { chat.enterPlanMode(description: $0) },
            redactor: { ChatTranscriptRedactor(secretValues: []) })
        desktop.rejectToolApproval = { snapshot in
            try N05DesktopCommandConsumer.denyPresentedToolApproval(approval, snapshot: snapshot)
        }
        let center = ComposerCommandAdjudicationCenter()
        center.desktopCommandAction = { request, snapshot in try desktop.execute(request, snapshot: snapshot) }
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        return (chat, center, approval)
    }

    @Test(arguments: [
        ("stop", "当前没有进行中的生成"),
        ("retry", "当前会话没有可重试的失败任务"),
        ("reject", "当前会话没有待审批的工具请求"),
    ])
    func unmetConditionShowsOneReasonAndChangesNothing(commandID: String, reason: String) throws {
        let (chat, center, _) = installed()
        defer { chat.onComposerCommandPolicy = nil }
        let before = chat.messages
        chat.draftText = "/" + commandID
        chat.submitComposer()
        #expect(chat.lastComposerCommandReceipt?.commandID == commandID)
        #expect(chat.lastComposerCommandReceipt?.disposition == .reject)
        #expect(center.projection?.text == "命令 \(commandID) 当前不可用：\(reason)")
        #expect(chat.messages == before)
        #expect(!chat.isActiveSessionGenerating)
    }
}

private struct N2WaitingProvider: LLMProvider, Sendable {
    let entered: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>
    let name = "Mock"
    var model = LLMModel(id: "mock-echo", displayName: "Offline stop command", provider: "Mock")
    let capabilities: Set<ProviderCapability> = [.streaming]
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        throw LLMError.unsupportedCapability(.tools)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        entered.yield(())
        var iterator = release.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("completed without interruption"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}
