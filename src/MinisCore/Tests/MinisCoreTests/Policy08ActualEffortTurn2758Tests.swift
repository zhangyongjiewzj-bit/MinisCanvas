import Foundation
import Testing
@testable import MinisCore

private final class Policy08ScriptedProvider2758: LLMProvider, @unchecked Sendable {
    var model = LLMModel(id: "policy08-local", displayName: "Policy08 Local", provider: "synthetic")
    var name: String { model.provider }
    var capabilities: Set<ProviderCapability> { [] }
    private(set) var tokenLimits: [Int] = []
    private(set) var histories: [[LLMMessage]] = []
    let allowedPath: String
    let deniedPath: String

    init(allowedPath: String, deniedPath: String) {
        self.allowedPath = allowedPath
        self.deniedPath = deniedPath
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        tokenLimits.append(maxTokens)
        histories.append(messages)
        let ordinal = tokenLimits.count
        guard ordinal <= 5 else {
            return LLMResponse(text: "completed after five tool attempts", stopReason: "stop", usage: nil)
        }
        let path = ordinal == 2 ? deniedPath : allowedPath
        let title = "Read the local effort sample"
        return LLMResponse(
            text: "read", stopReason: "tool_calls", usage: nil,
            toolCalls: [LLMToolCall(
                id: "policy08-call-\(ordinal)", name: "file_read",
                rawArguments: "{\"tool_title\":\"\(title)\",\"path\":\"\(path)\"}",
                arguments: ["tool_title": title, "path": path]
            )]
        )
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class Policy08NonExecution2758: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: [(String, ToolNonExecutionReason)] = []

    func record(callID: String, reason: ToolNonExecutionReason) {
        lock.withLock { observed.append((callID, reason)) }
    }

    var events: [(String, ToolNonExecutionReason)] { lock.withLock { observed } }
}

@Suite("D-POLICY-08 actual AgentLoop effort consumer")
struct Policy08ActualEffortTurn2758Tests {
    @Test func threeEffortsChangeIterationsAndProviderTokensButKeepToolReceipts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Policy08ActualTurn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed.txt")
        try "local-effort-sample".write(to: allowed, atomically: true, encoding: .utf8)
        let denied = root.deletingLastPathComponent()
            .appendingPathComponent("policy08-outside-\(UUID().uuidString).txt")
        let cases: [(ComposerEffort, Int, Int)] = [
            (.low, 5, 2048), (.standard, 10, 4096), (.high, 15, 6144)
        ]
        var commonStatuses: [ToolExecutionStatus]?

        for (effort, iterationLimit, tokenLimit) in cases {
            let now = Date()
            let session = "policy08-session-\(effort.rawValue)"
            let snapshot = ComposerSubmissionSnapshot(
                mode: .auto, approvalScope: .request, effort: effort,
                sessionID: session, turnID: 1, taskID: "policy08-\(effort.rawValue)",
                attemptID: "policy08-attempt-\(effort.rawValue)",
                messageID: "policy08-message-\(effort.rawValue)",
                workspaceID: "policy08-workspace", createdAt: now,
                policyRevision: "policy08-unchanged-policy", grantEpoch: "policy08-unchanged-grant",
                autonomyCeiling: .l3
            )
            let facts = ComposerPolicyFactSource(
                knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
                allowedWriteRoots: [root.path], workspaceID: snapshot.workspaceID,
                revision: snapshot.policyRevision, grantEpoch: snapshot.grantEpoch,
                leaseID: "policy08-unchanged-lease", expiresAt: now.addingTimeInterval(300),
                autonomyCeiling: .l3
            )
            let provider = Policy08ScriptedProvider2758(
                allowedPath: allowed.path, deniedPath: denied.path
            )
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(
                    sessionID: session, turnID: 1, messageID: snapshot.messageID
                ),
                operationID: "policy08-operation-\(effort.rawValue)", attempt: 1
            )
            let executor = ComposerPolicyEnforcedToolExecutor(
                base: BuiltinToolExecutor(allowedRoot: root),
                controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts)
            )
            let ledgerRoot = root.appendingPathComponent(effort.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: ledgerRoot, withIntermediateDirectories: true)
            let ledger = try minisCoreToolContractLedger(at: ledgerRoot)
            let nonExecution = Policy08NonExecution2758()
            var loop = AgentLoop(
                maxIterations: 10, loopDetector: nil, toolExecutionFactLedger: ledger
            )
            loop.onToolNonExecution = { callID, reason in
                nonExecution.record(callID: callID, reason: reason)
            }
            let outcome = await loop.runOutcome(
                messages: [LLMMessage(role: .user, content: "read the local sample")],
                systemPrompt: nil, provider: provider, toolExecutor: executor,
                tools: AgentToolCatalog.makeTools(), maxTokens: 4096,
                currentConversationID: session, composerSnapshot: snapshot,
                executionIdentity: identity
            )

            #expect(provider.tokenLimits.count == (effort == .low ? 5 : 6))
            #expect(provider.tokenLimits.allSatisfy { $0 == tokenLimit })
            if effort == .low {
                #expect(outcome.failure?.agentError == .maxIterationsExceeded(iterationLimit))
                #expect(outcome.result == nil)
            } else {
                #expect(outcome.failure == nil)
                #expect(outcome.result?.iterationCount == 6)
                #expect(outcome.result?.messages.last?.content == "completed after five tool attempts")
            }
            let statuses = outcome.toolExecutionFacts.map(\.status)
            // Policy rejects the second call before ledger mint. Only actual
            // dispatch attempts receive durable tool execution facts.
            #expect(statuses == [.succeeded, .succeeded, .succeeded, .succeeded])
            #expect(outcome.toolExecutionFacts.map(\.toolCallID) == [
                "policy08-call-1", "policy08-call-3", "policy08-call-4", "policy08-call-5"
            ])
            #expect(nonExecution.events.count == 1)
            #expect(nonExecution.events.first?.0 == "policy08-call-2")
            #expect(nonExecution.events.first?.1 == .blockedBeforeExecution)
            #expect(outcome.toolExecutionFacts.allSatisfy { !$0.receiptID.isEmpty })
            #expect(provider.histories.dropFirst().contains { history in
                history.contains { $0.content.contains("local-effort-sample") }
            })
            if let commonStatuses {
                #expect(statuses == commonStatuses)
            } else {
                commonStatuses = statuses
            }
        }
        #expect(!FileManager.default.fileExists(atPath: denied.path))
    }
}
