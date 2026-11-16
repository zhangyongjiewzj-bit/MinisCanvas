import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

private final class ProductionBudgetProvider: LLMProvider, @unchecked Sendable {
    var model = LLMModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", provider: "LUNA")
    var name: String { "LUNA" }
    var capabilities: Set<ProviderCapability> { [.streaming, .tools] }
    private(set) var calls = 0
    private(set) var receivedToolNames: [String] = []
    private(set) var receivedMaxTokens: [Int] = []
    var repeatToolCall = false

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        calls += 1
        receivedMaxTokens.append(maxTokens)
        if repeatToolCall {
            return LLMResponse(
                text: #"{"tool_calls":[{"id":"budget-call","name":"shell_execute","input":{"command":"true"}}]}"#,
                stopReason: "tool_use",
                usage: LLMUsage(inputTokens: 1, outputTokens: 0)
            )
        }
        return LLMResponse(
            text: "ok",
            stopReason: "stop",
            usage: LLMUsage(inputTokens: 1, outputTokens: 0)
        )
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedToolNames = tools.map(\.name)
        return try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}

@Suite("生产预算硬门禁接线")
struct ProductionBudgetWiringTests {
    @Test func budgetRecordingDecoratorForwardsNativeTools() async throws {
        let provider = ProductionBudgetProvider()
        let wrapped = BudgetRecordingProvider(base: provider, onRecorded: { _ in })

        _ = try await wrapped.sendMessage(
            messages: [LLMMessage(role: .user, content: "run")],
            systemPrompt: nil,
            tools: [AgentToolDefinition(
                name: "shell_execute",
                description: "Run one command",
                parameters: [:],
                required: []
            )],
            maxTokens: 16,
            temperature: nil
        )
        #expect(provider.receivedToolNames == ["shell_execute"])
    }

    @Test func composerEffortSnapshotReachesProductionLoopBudgets() async throws {
        let cases: [(ComposerEffort, Int, Int)] = [
            (.low, 5, 2048),
            (.standard, 10, 4096),
            (.high, 15, 6144),
        ]

        for (effort, expectedIterations, expectedTokens) in cases {
            let provider = ProductionBudgetProvider()
            provider.repeatToolCall = true
            let workspaceID = "composer-budget-\(effort.rawValue)"
            let facts = ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: workspaceID,
                revision: "budget-revision",
                grantEpoch: "budget-epoch",
                leaseID: "budget-lease",
                expiresAt: .distantFuture,
                autonomyCeiling: .l1
            )
            let snapshot = ComposerSubmissionSnapshot(
                mode: .manual,
                approvalScope: .request,
                effort: effort,
                sessionID: workspaceID,
                turnID: 1,
                taskID: "budget-task",
                messageID: "budget-assistant-\(effort.rawValue)",
                workspaceID: workspaceID,
                createdAt: Date(timeIntervalSince1970: 1),
                policyRevision: facts.revision,
                grantEpoch: facts.grantEpoch,
                autonomyCeiling: facts.autonomyCeiling
            )
            let engine = AgentLoopChatEngine(
                toolExecutor: BuiltinToolExecutor(
                    allowedRoot: FileManager.default.temporaryDirectory
                ),
                maxIterations: 10,
                composerPolicyFacts: facts
            )
            let stream = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "budget")],
                systemPrompt: "test",
                maxTokens: 4096,
                conversationID: workspaceID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: 1,
                composerSnapshot: snapshot
            )

            await #expect(throws: AgentLoopError.maxIterationsExceeded(expectedIterations)) {
                for try await _ in stream {}
            }
            #expect(provider.calls == expectedIterations)
            #expect(provider.receivedMaxTokens == Array(repeating: expectedTokens, count: expectedIterations))
        }
    }

    @Test func sharedTrackerBlocksTheNextTurnBeforeProviderCall() async throws {
        let provider = ProductionBudgetProvider()
        let tracker = BudgetTracker(RequestBudget(
            maxTokensPerSession: 1,
            overBudgetPolicy: .pause
        ))
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory),
            requestBudget: tracker
        )

        let first = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "first")],
            systemPrompt: "test",
            maxTokens: 16
        )
        await #expect(throws: AgentLoopError.budgetExhausted) {
            for try await _ in first {}
        }
        #expect(provider.calls == 1)
        #expect(await tracker.isExhausted)

        let second = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "second")],
            systemPrompt: "test",
            maxTokens: 16
        )
        await #expect(throws: AgentLoopError.self) {
            for try await _ in second {}
        }
        #expect(provider.calls == 1)
    }
}

@Suite("预算会话切换边界")
@MainActor
struct BudgetSessionBoundaryTests {
    @Test func sessionBoundaryUsesIndependentBudgetTrackerAndEngineSnapshot() async throws {
        let chat = ChatStore()
        let oldTracker = chat.budgetTracker
        let oldEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(
                allowedRoot: FileManager.default.temporaryDirectory
            ),
            requestBudget: oldTracker
        )
        chat.agentEngine = oldEngine

        chat.newSession()

        let newTracker = chat.budgetTracker
        #expect(newTracker !== oldTracker)
        let newEngine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(newEngine.requestBudget === newTracker)
        #expect(newEngine.requestBudget !== oldTracker)
        #expect(oldEngine.requestBudget === oldTracker)
    }

    @Test func immediateSendAfterNewSessionUsesFreshTrackerGeneration() async throws {
        let chat = ChatStore()
        let provider = ProductionBudgetProvider()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID,
            revision: "budget-test-revision",
            grantEpoch: "budget-test-epoch",
            leaseID: "budget-test-lease",
            expiresAt: .distantFuture,
            autonomyCeiling: .l1
        )
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            bypassModeConfirmed: false
        )
        let skillRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "production-budget-skill-snapshot-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: skillRoot) }
        let skillInjector = SkillInjector(
            store: SkillStore(skillsRoot: skillRoot)
        )
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: skillInjector.snapshotForTurn(),
                // The fixture intentionally freezes an empty MCP witness; the
                // test is about budget/session generation, not live tool I/O.
                mcpBridge: nil
            )
        }
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(
                allowedRoot: FileManager.default.temporaryDirectory
            ),
            requestBudget: chat.budgetTracker,
            composerPolicyFacts: facts
        )
        chat.agentEngine = engine
        chat.streamingProviderOverride = provider

        _ = await chat.budgetTracker.record(requestTokens: RequestBudget.defaultMaxTokensPerSession)
        #expect(await chat.budgetTracker.shouldBlockNewRequests)

        chat.newSession()
        chat.draftText = "新会话立即发送"
        chat.sendDraft()

        var waited = 0
        while provider.calls == 0 && waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(
            provider.calls == 1,
            "新会话首回合未到 Provider，messages=\(chat.messages.map(\.content))"
        )
        chat.stopStreaming()
    }
}
