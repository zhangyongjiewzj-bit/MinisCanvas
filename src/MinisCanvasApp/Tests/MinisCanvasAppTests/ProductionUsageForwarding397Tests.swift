import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

// D-PROVIDER-15: scripted Providers, never a replacement ChatAgentEngine.
// Production route -> AgentLoopChatEngine/SecureAgentLoopFactory ->
// ChatStore's fenced .usage consumer -> the fixture-owned canonical UsageStore.
private actor Usage397Script {
    let responses: [LLMResponse]
    let fails: Bool
    let waitsForRelease: Bool
    private(set) var calls = 0
    private(set) var bufferedCalls = 0
    private(set) var streamingCalls = 0
    private(set) var completedResponses = 0
    private(set) var receivedMessages: [[LLMMessage]] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(_ responses: [LLMResponse], fails: Bool = false, waitsForRelease: Bool = false) {
        self.responses = responses
        self.fails = fails
        self.waitsForRelease = waitsForRelease
    }

    func next(streaming: Bool, messages: [LLMMessage]) async throws -> LLMResponse {
        receivedMessages.append(messages)
        calls += 1
        if streaming { streamingCalls += 1 } else { bufferedCalls += 1 }
        let index = calls - 1
        if waitsForRelease {
            // Deliberately cancellation-insensitive: the production fence must
            // reject a complete response arriving after Stop/new-session.
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        if fails { throw LLMError.providerError(message: "synthetic failure") }
        guard responses.indices.contains(index) else {
            throw LLMError.providerError(message: "synthetic script exhausted")
        }
        completedResponses += 1
        return responses[index]
    }

    var isWaiting: Bool { releaseWaiter != nil }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private final class Usage397BufferedProvider: LLMProvider, @unchecked Sendable {
    let name = "usage397-synthetic"
    var model = LLMModel(id: "usage397-model", displayName: "Usage397", provider: "usage397-synthetic")
    var capabilities: Set<ProviderCapability> { [.tools] }
    let script: Usage397Script
    init(_ script: Usage397Script) { self.script = script }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await script.next(streaming: false, messages: messages)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await script.next(streaming: false, messages: messages)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

private final class Usage397StreamingProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    let base: Usage397BufferedProvider
    init(_ script: Usage397Script) { base = Usage397BufferedProvider(script) }
    var name: String { base.name }
    var model: LLMModel {
        get { base.model }
        set { base.model = newValue }
    }
    var capabilities: Set<ProviderCapability> { [.tools, .streaming] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await base.sendMessage(messages: messages, systemPrompt: systemPrompt,
                                   maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await base.sendMessage(messages: messages, systemPrompt: systemPrompt,
                                   tools: tools, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
                                tools: [AgentToolDefinition], maxTokens: Int,
                                temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let response = try await base.script.next(streaming: true, messages: messages)
        return AsyncThrowingStream { continuation in
            if response.toolCalls.isEmpty {
                continuation.yield(.textDelta("synthetic "))
                continuation.yield(.textDelta("reply"))
            }
            continuation.yield(.completed(response))
            continuation.finish()
        }
    }
}

private final class Usage397Executor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    private func recordCall() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
    func execute(name: String, input: [String: Any]) async throws -> String {
        recordCall()
        return "synthetic tool result"
    }
}

@Suite("D-PROVIDER-15 production complete-response usage forwarding")
@MainActor
struct ProductionUsageForwarding397Tests {
    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let chat: ChatStore
        let usage: UsageStore
        let executor: Usage397Executor
        let logManager: LogManager
        let approvalCenter: ApprovalPromptCenter

        func dispose() async {
            chat.stopAllStreamingForSafety()
            _ = await usage.waitForPersistence()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(provider: any LLMProvider) throws -> Fixture {
        let suite = "ProductionUsageForwarding397-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let usage = UsageStore(domain: .suite(suite))
        let logManager = LogManager(directory: root, ringCapacity: 40)
        let chat = ChatStore(preferencesDefaults: defaults, logManager: logManager)
        chat.composerSubmissionDiagnosticsEnabled = true
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["shell_execute"], grantedCapabilities: ["shell_execute"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID,
            revision: "usage397-policy", grantEpoch: "usage397-epoch",
            leaseID: "usage397-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let injector = SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            // This is the same frozen route consumer used by production turns.
            // The passed Provider is synthetic; no key, env, or transport is read.
            let snapshot = try! ProviderRuntimeSnapshot(
                providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:usage397")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        let executor = Usage397Executor()
        let approvalCenter = ApprovalPromptCenter()
        // Exercise the secure production factory with a real policy binding,
        // while the innermost executor remains a synthetic call recorder.
        let now = Date()
        let goal = GoalEnvelope(scopeID: "usage397-synthetic-scope",
            allowedCapabilities: ["shell_execute"], fileRoots: [root.path],
            budget: 100, deadline: now.addingTimeInterval(3_600),
            concurrencyLimit: 1, autonomyLevel: .l3,
            creatorID: "ProductionUsageForwarding397Tests", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                                  issuedAt: now, expiresAt: goal.deadline)
        let policyExecutor = PolicyRuntimeBinding(goal: goal, lease: lease).wrap(executor)
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: policyExecutor,
            requestBudget: chat.budgetTracker,
            approvalGate: ApprovalGate(policyByTool: ["shell_execute": .autoApprove],
                delegate: ApprovalPromptDelegate(center: approvalCenter)),
            onContextPreparation: {
                logManager.info("context-preparation-entered",
                                category: "Usage397Diagnostic", eventID: "usage397.context.entered")
            },
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")),
            composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        chat.usageStore = usage
        return Fixture(root: root, suite: suite, chat: chat, usage: usage, executor: executor,
                       logManager: logManager, approvalCenter: approvalCenter)
    }

    private func response(input: Int = 5, output: Int = 2, read: Int = 4,
                          creation: Int = 3) -> LLMResponse {
        LLMResponse(text: "synthetic reply", stopReason: "stop",
            usage: LLMUsage(inputTokens: input, outputTokens: output,
                           cacheCreationInputTokens: creation, cacheReadInputTokens: read))
    }

    private func trace(_ f: Fixture, stage: String) {
        // The fixture owns every message, provider and log. No credential/env
        // source is inspected; fixed submission stages use existing redaction.
        let diagnostics = f.logManager.recentLogs().filter {
            $0.eventID == "composer.submit.stage" || $0.eventID == "usage397.context.entered"
        }.map(\.message)
        let assistantMessages = f.chat.messages.filter { $0.role == .assistant }.map {
            LogEntry(level: .info, category: "Usage397Diagnostic", message: $0.content).message
        }
        let value: [String: Any] = [
            "stage": stage, "hasSession": f.chat.activeSessionID != nil,
            "isStreaming": f.chat.isStreaming,
            "invalidSettings": f.chat.lastSubmissionBlockedByInvalidSettings,
            "submissionPresent": f.chat.lastComposerSubmissionSnapshot != nil,
            "submissionStages": diagnostics, "assistantMessages": assistantMessages
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("USAGE397_SYNTHETIC_TRACE " + text)
        }
    }

    @discardableResult
    private func sendAndSettle(_ f: Fixture) async throws -> [ApprovalRequest] {
        var approvedRequests: [ApprovalRequest] = []
        f.chat.draftText = "synthetic usage turn"
        f.chat.submitComposer()
        trace(f, stage: "submitted")
        for _ in 0..<500 where f.chat.isStreaming {
            if let pending = f.approvalCenter.pendingRequest {
                // R23's original global/input-risk intersection must receive
                // real App approval, even though this controlled executor has
                // no OS effects. No auto-grant or permission-policy change.
                #expect(pending.toolName == "shell_execute" && pending.requiresApproval)
                #expect(pending.callID == "usage397-call" && pending.identityDigest?.count == 64)
                #expect(pending.requiresSecondConfirmation)
                #expect(f.executor.calls == 0)
                let lifecycleID = try #require(f.approvalCenter.pendingRequestLifecycleID)
                let confirming = f.approvalCenter.awaitingConfirmation
                // The real action guards each presented step for 500 ms.
                try await Task.sleep(for: .milliseconds(550))
                guard f.approvalCenter.pendingRequestLifecycleID == lifecycleID,
                      f.approvalCenter.pendingRequest?.id == pending.id,
                      f.approvalCenter.awaitingConfirmation == confirming,
                      f.approvalCenter.isPromptPresented else { continue }
                #expect(f.executor.calls == 0)
                f.approvalCenter.actionsForPresentedRequest().approve()
                if confirming {
                    if f.approvalCenter.pendingRequestLifecycleID != lifecycleID {
                        approvedRequests.append(pending)
                    }
                } else {
                    #expect(f.approvalCenter.awaitingConfirmation && f.executor.calls == 0)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        trace(f, stage: "settled")
        #expect(!f.chat.isStreaming, "production turn must reach its real terminal")
        #expect(await f.usage.waitForPersistence())
        return approvedRequests
    }

    @Test func bufferedProductionResponseReachesCanonicalStoreOnce() async throws {
        let script = Usage397Script([response()])
        let f = try fixture(provider: Usage397BufferedProvider(script))
        try await sendAndSettle(f)
        #expect(await script.bufferedCalls == 1)
        #expect(f.usage.totalCalls == 1)
        #expect(f.usage.totalInputTokens == 5 && f.usage.totalOutputTokens == 2)
        #expect(f.usage.totalCacheReadTokens == 4 && f.usage.totalCacheCreationTokens == 3)
        #expect(f.usage.callHistory.count == 1)
        #expect(f.usage.callHistory.first?.sessionID == f.chat.activeSessionID?.uuidString)
        #expect(f.chat.budgetUsedTokens == 7)
        let reopened = UsageStore(domain: .suite(f.suite))
        #expect(await reopened.waitForPersistence())
        #expect(reopened.totalCalls == 1 && reopened.totalTokens == 7)
        #expect(reopened.callHistory.first?.sessionID == f.chat.activeSessionID?.uuidString)
        await f.dispose()
    }

    @Test func assistantStreamCompletedUsageCountsOnceDespiteTextDeltas() async throws {
        let script = Usage397Script([response()])
        let f = try fixture(provider: Usage397StreamingProvider(script))
        try await sendAndSettle(f)
        #expect(await script.streamingCalls == 1)
        #expect(await script.bufferedCalls == 0)
        #expect(f.usage.totalCalls == 1 && f.usage.totalTokens == 7)
        #expect(f.usage.totalCacheReadTokens == 4 && f.usage.totalCacheCreationTokens == 3)
        #expect(f.chat.budgetUsedTokens == 7)
        await f.dispose()
    }

    @Test func toolLoopRecordsEachSuccessfulResponseInsteadOfReplacingUsage() async throws {
        let tool = LLMResponse(text: "", stopReason: "tool_use", usage: response().usage,
            toolCalls: [LLMToolCall(id: "usage397-call", name: "shell_execute",
                rawArguments: "{\"command\":\"synthetic\"}", arguments: ["command": "synthetic"])])
        let script = Usage397Script([tool, response(input: 11, output: 3, read: 6, creation: 1)])
        let f = try fixture(provider: Usage397StreamingProvider(script))
        let approvals = try await sendAndSettle(f)
        #expect(await script.calls == 2)
        #expect(f.executor.calls == 1)
        #expect(f.usage.totalCalls == 2 && f.usage.callHistory.count == 2)
        #expect(f.usage.totalInputTokens == 16 && f.usage.totalOutputTokens == 5)
        #expect(f.usage.totalCacheReadTokens == 10 && f.usage.totalCacheCreationTokens == 4)
        #expect(f.chat.budgetUsedTokens == 21)
        #expect(approvals.count == 1 && f.approvalCenter.pendingRequest == nil)
        let request = try #require(approvals.first)
        let frozen = try #require(f.chat.lastComposerSubmissionSnapshot)
        #expect(request.sessionID == frozen.sessionID && request.turnID == frozen.turnID)
        #expect(request.taskID == frozen.taskID && request.attemptID == frozen.attemptID)
        #expect(request.messageID == frozen.messageID && request.policyRevision == frozen.policyRevision && request.grantEpoch == frozen.grantEpoch)
        let received = await script.receivedMessages
        #expect(received.count == 2)
        let lastRequest = try #require(received.last)
        // Native LLMToolCall responses use the production OpenAI tool role,
        // not the legacy JSON envelope consumed by toAgentContentParts().
        let results = lastRequest.filter { $0.role == .tool && $0.toolCallID == "usage397-call" }
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.toolCallID == "usage397-call" && result.role == .tool)
        #expect(result.content == "synthetic tool result")
        #expect(!result.content.hasPrefix("Error executing tool"))
        let engine = try #require(f.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == 1 && engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        #expect(engine.toolExecutionFactLedger.facts.first?.status == .succeeded)
        print("USAGE397_ACTUAL_APPROVED toolCalls=1 providerResponses=2 usageCalls=2 tokens=21 realSecondConfirmation=true")
        await f.dispose()
    }

    @Test func missingUsageAndFailedResponseDoNotManufactureZeroRecords() async throws {
        for fails in [false, true] {
            let script = Usage397Script([LLMResponse(text: "synthetic reply", stopReason: "stop", usage: nil)],
                                        fails: fails)
            let f = try fixture(provider: Usage397BufferedProvider(script))
            try await sendAndSettle(f)
            #expect(await script.calls == 1)
            #expect(await script.completedResponses == (fails ? 0 : 1))
            #expect(f.usage.totalCalls == 0 && f.usage.callHistory.isEmpty)
            #expect(f.usage.totalTokens == 0)
            await f.dispose()
        }
    }

    @Test func stoppedLateResponseCannotRecordIntoANewSession() async throws {
        let late = Usage397Script([response(input: 100, output: 50)], waitsForRelease: true)
        let f = try fixture(provider: Usage397BufferedProvider(late))
        let originalSessionID = try #require(f.chat.activeSessionID)
        f.chat.draftText = "synthetic late turn"
        f.chat.submitComposer()
        trace(f, stage: "submitted")
        for _ in 0..<500 {
            if await late.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        trace(f, stage: "late-wait-observation")
        #expect(await late.isWaiting)
        f.chat.stopStreaming()
        f.chat.newSession()
        await late.release()
        let fresh = Usage397Script([response(input: 2, output: 1, read: 0, creation: 0)])
        f.chat.streamingProviderOverride = Usage397BufferedProvider(fresh)
        try await sendAndSettle(f)
        #expect(await fresh.calls == 1)
        for _ in 0..<100 {
            if await late.completedResponses == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await late.completedResponses == 1, "late telemetry must actually have returned")
        #expect(await f.usage.waitForPersistence())
        #expect(f.usage.totalCalls == 1 && f.usage.totalTokens == 3)
        #expect(f.usage.callHistory.allSatisfy { $0.inputTokens == 2 })
        #expect(f.usage.callHistory.allSatisfy { $0.sessionID == f.chat.activeSessionID?.uuidString })
        #expect(UsageFilteredSettingsView.sessionRecords(from: f.usage, sessionID: originalSessionID.uuidString).isEmpty)
        await f.dispose()
    }
}
