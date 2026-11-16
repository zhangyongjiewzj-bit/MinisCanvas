import Foundation
import Testing
@testable import MinisCore

struct ComposerEffortExecutionProfileTests {
    private func snapshot(effort: ComposerEffort) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: effort,
            sessionID: "session-test",
            turnID: 7,
            taskID: "task-test",
            attemptID: "effort-test-attempt",
            messageID: "effort-test-assistant",
            workspaceID: "workspace-test",
            createdAt: Date(timeIntervalSince1970: 1),
            policyRevision: "policy-test",
            grantEpoch: "effort-test-grant",
            autonomyCeiling: .l1
        )
    }

    @Test
    func standardPreservesBaseBudget() {
        let profile = ComposerEffortExecutionProfile(
            effort: .standard,
            baseMaxIterations: 10,
            baseMaxTokens: 4096
        )

        #expect(profile.maxIterations == 10)
        #expect(profile.maxTokens == 4096)
    }

    @Test
    func lowAndHighProduceBoundedObservableDifferences() {
        let low = ComposerEffortExecutionProfile(
            effort: .low,
            baseMaxIterations: 10,
            baseMaxTokens: 4096
        )
        let standard = ComposerEffortExecutionProfile(
            effort: .standard,
            baseMaxIterations: 10,
            baseMaxTokens: 4096
        )
        let high = ComposerEffortExecutionProfile(
            effort: .high,
            baseMaxIterations: 10,
            baseMaxTokens: 4096
        )

        #expect(low.maxIterations < standard.maxIterations)
        #expect(low.maxTokens < standard.maxTokens)
        #expect(high.maxIterations > standard.maxIterations)
        #expect(high.maxTokens > standard.maxTokens)
        #expect(high.maxIterations <= ComposerEffortExecutionProfile.maxIterationCap)
        #expect(high.maxTokens <= ComposerEffortExecutionProfile.maxTokenCap)
    }

    @Test
    func invalidBasesClampWithoutZeroBudget() {
        let profile = ComposerEffortExecutionProfile(
            effort: .high,
            baseMaxIterations: 0,
            baseMaxTokens: -1
        )

        #expect(profile.maxIterations == 1)
        #expect(profile.maxTokens == 1)
    }

    @Test
    func snapshotInitializerUsesTheImmutableTurnEffort() {
        let snapshot = snapshot(effort: .high)
        let profile = ComposerEffortExecutionProfile(
            snapshot: snapshot,
            baseMaxIterations: 10,
            baseMaxTokens: 4096
        )

        #expect(profile.effort == .high)
        #expect(profile.maxIterations == 15)
        #expect(profile.maxTokens == 6144)
    }

    @Test
    func selectedContextCeilingBoundsEachEffortWithoutReplacingTheBase() {
        let cases: [(ComposerEffort, Int)] = [
            (.low, 500), (.standard, 1000), (.high, 1500)
        ]
        for (effort, expected) in cases {
            let profile = ComposerEffortExecutionProfile(
                snapshot: snapshot(effort: effort),
                baseMaxIterations: 10,
                baseMaxTokens: 1000,
                maxOutputTokensCeiling: 8000
            )
            #expect(profile.maxTokens == expected)
        }
        #expect(ComposerEffortExecutionProfile(
            snapshot: snapshot(effort: .high),
            baseMaxIterations: 10,
            baseMaxTokens: 1000,
            maxOutputTokensCeiling: 1200
        ).maxTokens == 1200)
        #expect(ComposerEffortExecutionProfile(
            snapshot: snapshot(effort: .high),
            baseMaxIterations: 10,
            baseMaxTokens: 4096,
            maxOutputTokensCeiling: 10
        ).maxTokens == 10)
        #expect(ComposerEffortExecutionProfile(
            snapshot: snapshot(effort: .high),
            baseMaxIterations: 10,
            baseMaxTokens: Int.max,
            maxOutputTokensCeiling: Int.max
        ).maxTokens == ComposerEffortExecutionProfile.maxTokenCap)
    }

    @Test
    func agentLoopPassesSnapshotBudgetToTheProvider() async throws {
        let provider = ComposerBudgetCapturingProvider()
        let snapshot = snapshot(effort: .low)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerEffortExecutionProfileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await AgentLoop(
            maxIterations: 10,
            loopDetector: nil
        ).run(
            messages: [LLMMessage(role: .user, content: "test")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            tools: [],
            maxTokens: 4096,
            composerSnapshot: snapshot
        )

        #expect(provider.receivedMaxTokens == [2048])
    }

    @Test
    func highEffortCannotExceedAContextClippedOutputBudget() async throws {
        let provider = ComposerBudgetCapturingProvider()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerEffortContextCeiling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await AgentLoop(maxIterations: 10, loopDetector: nil).run(
            messages: [LLMMessage(role: .user, content: "test")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            tools: [],
            // The App has already clipped the request to ten tokens of
            // remaining user-selected context before calling AgentLoop.
            maxTokens: 10,
            maxOutputTokensCeiling: 10,
            composerSnapshot: snapshot(effort: .high)
        )

        #expect(provider.receivedMaxTokens == [10])
    }

    @Test
    func exhaustedOutputCeilingRejectsBeforeProviderCall() async throws {
        let provider = ComposerBudgetCapturingProvider()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerEffortEmptyCeiling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        await #expect(throws: AgentLoopError.outputTokenCeilingExhausted) {
            _ = try await AgentLoop(maxIterations: 10, loopDetector: nil).run(
                messages: [LLMMessage(role: .user, content: "test")],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: BuiltinToolExecutor(allowedRoot: root),
                tools: [],
                maxTokens: 1000,
                maxOutputTokensCeiling: 0,
                composerSnapshot: snapshot(effort: .high)
            )
        }
        #expect(provider.receivedMaxTokens.isEmpty)
    }

    @Test(arguments: [
        (ComposerEffort.low, 500),
        (.standard, 1000),
        (.high, 1200)
    ])
    func selectedContextRecomputesAfterToolResult(
        effort: ComposerEffort, expectedInitialCap: Int
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerContextPerRequest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("synthetic-tool-result.txt")
        try String(repeating: "x", count: 2_400).write(to: path, atomically: true, encoding: .utf8)
        let provider = ComposerBudgetCapturingProvider(responses: [
            toolCallResponse(path: path.path),
            LLMResponse(text: "done", stopReason: "stop", usage: nil)
        ])
        let settings = try #require(contextSettings(length: 1_600))
        let first = [LLMMessage(role: .user, content: "read")]
        let firstCost = try #require(AgentContextTokenBudget.estimatedInputCost(
            first, systemPrompt: "system"
        ))
        let submission = snapshot(effort: effort)
        let result = try await AgentLoop(
            maxIterations: 10,
            loopDetector: nil,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        ).run(
            messages: first,
            systemPrompt: "system",
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            tools: AgentToolCatalog.makeTools(),
            maxTokens: 1000,
            maxOutputTokensCeiling: min(1_600 - firstCost, 1200),
            contextSettings: settings,
            currentConversationID: submission.sessionID,
            composerSnapshot: submission,
            executionIdentity: toolIdentity(for: submission)
        )
        #expect(result.toolCallsExecuted == 1)
        #expect(provider.receivedMaxTokens.count == 2)
        #expect(provider.receivedMaxTokens.first == expectedInitialCap)
        let second = try #require(provider.receivedHistory.last)
        #expect(second.contains { $0.role == .tool && $0.content.contains(String(repeating: "x", count: 100)) })
        let secondCost = try #require(AgentContextTokenBudget.estimatedInputCost(
            second, systemPrompt: "system"
        ))
        #expect(provider.receivedMaxTokens.last == min(expectedInitialCap, 1_600 - secondCost))
        #expect(1_600 - secondCost < expectedInitialCap || effort == .low)
    }

    @Test
    func selectedContextExhaustionBlocksSecondProviderCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerContextExhausted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("synthetic-tool-result.txt")
        try String(repeating: "z", count: 5_000).write(to: path, atomically: true, encoding: .utf8)
        let provider = ComposerBudgetCapturingProvider(responses: [
            toolCallResponse(path: path.path),
            LLMResponse(text: "unexpected", stopReason: "stop", usage: nil)
        ])
        let settings = try #require(contextSettings(length: 500))
        let capture = ComposerBudgetFailureCapture()
        await #expect(throws: AgentLoopError.outputTokenCeilingExhausted) {
            _ = try await AgentLoop(
                maxIterations: 10,
                loopDetector: nil,
                toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
            ).run(
                messages: [LLMMessage(role: .user, content: "read")],
                systemPrompt: "system",
                provider: provider,
                toolExecutor: BuiltinToolExecutor(allowedRoot: root),
                tools: AgentToolCatalog.makeTools(),
                maxTokens: 1000,
                contextSettings: settings,
                currentConversationID: "session-test",
                executionIdentity: AgentExecutionIdentity(
                    turn: AgentTurnIdentity(
                        sessionID: "session-test", turnID: 1,
                        messageID: "context-exhaustion-assistant"
                    ),
                    operationID: "context-exhaustion-operation",
                    attempt: 1
                ),
                onFailure: { capture.store($0) }
            )
        }
        #expect(provider.receivedMaxTokens.count == 1)
        #expect(capture.messages.contains {
            $0.role == .tool && $0.content.contains(String(repeating: "z", count: 100))
        })
    }

    @Test
    func unselectedContextRetainsFixedPerRequestBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerContextUnselected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("synthetic-tool-result.txt")
        try String(repeating: "u", count: 2_400).write(to: path, atomically: true, encoding: .utf8)
        let provider = ComposerBudgetCapturingProvider(responses: [
            toolCallResponse(path: path.path),
            LLMResponse(text: "done", stopReason: "stop", usage: nil)
        ])
        let settings = try #require(ContextTurnSettingsSnapshot(
            sessionID: "session-test", modelID: provider.model.id,
            modelContextWindowTokens: 8192,
            requestedContextLengthTokens: nil, historyTurnLimit: nil
        ))
        let submission = snapshot(effort: .high)
        _ = try await AgentLoop(
            maxIterations: 10,
            loopDetector: nil,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        ).run(
            messages: [LLMMessage(role: .user, content: "read")],
            systemPrompt: "system",
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            tools: AgentToolCatalog.makeTools(),
            maxTokens: 1000,
            contextSettings: settings,
            currentConversationID: submission.sessionID,
            composerSnapshot: submission,
            executionIdentity: toolIdentity(for: submission)
        )
        #expect(provider.receivedMaxTokens == [1500, 1500])
    }

    private func contextSettings(length: Int) -> ContextTurnSettingsSnapshot? {
        ContextTurnSettingsSnapshot(
            sessionID: "session-test", modelID: "gpt-5.6-luna",
            modelContextWindowTokens: 8192,
            requestedContextLengthTokens: length, historyTurnLimit: nil
        )
    }

    private func toolIdentity(for snapshot: ComposerSubmissionSnapshot) -> AgentExecutionIdentity {
        AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: snapshot.sessionID,
                turnID: snapshot.turnID,
                messageID: snapshot.messageID
            ),
            operationID: "effort-test-operation-\(UUID().uuidString)",
            attempt: 1
        )
    }

    private func toolCallResponse(path: String) -> LLMResponse {
        let title = "Read the synthetic tool result file"
        let rawArguments = "{\"tool_title\":\"\(title)\",\"path\":\"\(path)\"}"
        return LLMResponse(
            text: "reading", stopReason: "tool_calls", usage: nil,
            toolCalls: [LLMToolCall(
                id: "synthetic-call", name: "file_read",
                rawArguments: rawArguments,
                arguments: ["tool_title": title, "path": path]
            )]
        )
    }
}

private final class ComposerBudgetCapturingProvider: LLMProvider, @unchecked Sendable {
    var model = LLMModel(
        id: "gpt-5.6-luna",
        displayName: "GPT-5.6 Luna",
        provider: "LUNA"
    )
    var name: String { "LUNA" }
    var capabilities: Set<ProviderCapability> { [] }
    private(set) var receivedMaxTokens: [Int] = []
    private(set) var receivedHistory: [[LLMMessage]] = []
    private let responses: [LLMResponse]

    init(responses: [LLMResponse] = []) {
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedHistory.append(messages)
        receivedMaxTokens.append(maxTokens)
        if receivedHistory.count <= responses.count {
            return responses[receivedHistory.count - 1]
        }
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
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
            continuation.finish()
        }
    }
}

private final class ComposerBudgetFailureCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LLMMessage] = []

    var messages: [LLMMessage] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ messages: [LLMMessage]) {
        lock.lock()
        stored = messages
        lock.unlock()
    }
}

struct CCRound2IterationLimitTests {
    @Test func standardUsesFiftyAndOneHundredWithoutThirtyTwoCap() {
        for limit in [50, 100] {
            let profile = ComposerEffortExecutionProfile(effort: .standard,
                baseMaxIterations: limit, baseMaxTokens: 4096)
            #expect(profile.maxIterations == limit)
        }
        #expect(AgentLoop().maxIterations == 50)
        #expect(AgentLoop(maxIterations: 999).maxIterations == 100)
    }

    @Test func parentBindingCompositionIsSingleAssignment() throws {
        let first = ParentContextSnapshotV1(providerID: "synthetic", modelID: "a", configurationFingerprint: "frozen")
        let other = ParentContextSnapshotV1(providerID: "synthetic", modelID: "b", configurationFingerprint: "frozen")
        let original = AgentLoop(maxIterations: 75)
        let bound = try original.withParentBinding(first)
        #expect(original.parentBinding == nil)
        #expect(bound.maxIterations == 75)
        #expect(bound.parentBinding == first)
        #expect(throws: (any Error).self) { try bound.withParentBinding(other) }
    }
}
