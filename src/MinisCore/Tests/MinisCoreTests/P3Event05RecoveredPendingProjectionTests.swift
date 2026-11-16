import Foundation
import Testing
@testable import MinisCore

private final class Event05HeldTool: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var released = false
    private var releaseContinuation: CheckedContinuation<String, Error>?

    var calls: Int { lock.withLock { count } }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { count += 1 }
        return try await withCheckedThrowingContinuation { continuation in
            let shouldRelease = lock.withLock { () -> Bool in
                if released { return true }
                releaseContinuation = continuation
                return false
            }
            if shouldRelease { continuation.resume(returning: "synthetic result") }
        }
    }

    func waitForEntry() async -> Bool {
        for _ in 0..<250 {
            if lock.withLock({ releaseContinuation != nil }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            released = true
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume(returning: "synthetic result")
    }
}

@Suite("EVENT5 recovered pending is an observation, never a retry")
struct P3Event05RecoveredPendingProjectionTests {
    @Test("AgentLoop mint then takeover keeps UNKNOWN and blocks same-key redispatch")
    func agentLoopInterruptionAndReload() async throws {
        let root = try minisCoreToolContractRoot("event05-held")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstLedger = try minisCoreToolContractLedger(at: root)
        let identity = minisCoreToolContractIdentity("event05-held")
        let executor = Event05HeldTool()
        let envelope = #"{"tool_calls":[{"id":"held-call","name":"file_read","input":{"path":"/tmp/synthetic-event05"}}]}"#
        let firstRun = Task {
            let loop = AgentLoop(maxIterations: 2, toolExecutionFactLedger: firstLedger)
            return try await loop.run(
                messages: [], systemPrompt: nil,
                provider: MockLLMProvider(responses: [envelope, "done"]),
                toolExecutor: executor,
                tools: minisCoreToolContractCatalog(["file_read"]),
                executionIdentity: identity
            )
        }
        defer {
            firstRun.cancel()
            executor.release()
        }
        guard await executor.waitForEntry() else {
            Issue.record("AgentLoop did not reach the held executor")
            return
        }
        #expect(executor.calls == 1)
        #expect(firstLedger.recoveredPendingReceipts.isEmpty)
        let recovered = try minisCoreToolContractLedger(at: root)
        let receipt = try #require(recovered.recoveredPendingReceipts.first)
        #expect(recovered.pendingReceipts == [receipt])
        #expect(recovered.facts.isEmpty)

        let unknown = ConversationEventProjection().projectingRecoveredPendingTools(
            recovered.recoveredPendingReceipts,
            activeExecutions: [],
            occurredAt: Date(timeIntervalSince1970: 1)
        )
        #expect(unknown.toolLifecycleEvents.count == 1)
        #expect(unknown.toolLifecycleEvents.first?.status == .needsReview)
        #expect(unknown.approvalHistory.isEmpty)

        let retryLoop = AgentLoop(maxIterations: 2, toolExecutionFactLedger: recovered)
        _ = try await retryLoop.run(
            messages: [], systemPrompt: nil,
            provider: MockLLMProvider(responses: [envelope, "done"]),
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_read"]),
            executionIdentity: identity
        )
        #expect(executor.calls == 1)
        #expect(recovered.pendingReceipts == [receipt])
        #expect(recovered.facts.isEmpty)
        firstRun.cancel()
        executor.release()
        _ = try? await firstRun.value
    }

    @Test("only recovered pending projects; exact key isolates sessions and active executions")
    func recoveryProjectionIdentityAndLiveBoundary() throws {
        let root = try minisCoreToolContractRoot("event05-projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try minisCoreToolContractLedger(at: root)
        let identityA = minisCoreToolContractIdentity("a", sessionID: "session-A")
        let identityB = minisCoreToolContractIdentity("b", sessionID: "session-B")
        let a = try first.mint(toolCallID: "same-call", toolName: "file_read",
            attemptID: "attempt-A", attemptNumber: 1, executionIdentity: identityA)
        let b = try first.mint(toolCallID: "same-call", toolName: "file_read",
            attemptID: "attempt-B", attemptNumber: 1, executionIdentity: identityB)
        #expect(first.recoveredPendingReceipts.isEmpty)
        #expect(ConversationEventProjection().projectingRecoveredPendingTools(
            first.recoveredPendingReceipts, activeExecutions: [], occurredAt: .now
        ).events.isEmpty)

        let reloaded = try minisCoreToolContractLedger(at: root)
        let base = ConversationEventProjection(events: [
            ConversationEvent(
                id: try #require(a.compositeKey).rawValue,
                identity: try #require(ConversationEventIdentity(
                    sessionID: "session-A", turnID: "1", taskID: "task-A",
                    attempt: 1, scopeID: "scope-A")),
                sequence: 1, occurredAt: Date(timeIntervalSince1970: 1),
                kind: .tool, status: .running, summary: "工具运行：file_read",
                toolName: "file_read", toolCallID: "same-call",
                toolCompositeKey: a.compositeKey
            )
        ])
        let active = base.projectingRecoveredPendingTools(
            reloaded.recoveredPendingReceipts,
            activeExecutions: [identityA], occurredAt: Date(timeIntervalSince1970: 2)
        )
        #expect(active.toolLifecycleEvents.first { $0.identity.sessionID == "session-A" }?.status == .running)
        #expect(active.toolLifecycleEvents.first { $0.identity.sessionID == "session-B" }?.status == .needsReview)

        let projected = base.projectingRecoveredPendingTools(
            reloaded.recoveredPendingReceipts,
            activeExecutions: [], occurredAt: Date(timeIntervalSince1970: 2)
        )
        #expect(projected.toolLifecycleEvents.count == 2)
        #expect(projected.toolLifecycleEvents.allSatisfy { $0.status == .needsReview })
        #expect(projected.toolLifecycleEvents.first { $0.identity.sessionID == "session-A" }?.identity.taskID == "task-A")
        #expect(projected.toolLifecycleEvents.first { $0.identity.sessionID == "session-B" }?.identity.taskID.hasPrefix("recovered-tool:") == true)
        #expect(projected.approvalHistory.isEmpty)
        #expect(base.toolLifecycleEvents.first?.status == .running)
        let terminalButStillPending = ConversationEventProjection(events: [
            ConversationEvent(
                id: a.receiptID,
                identity: try #require(ConversationEventIdentity(
                    sessionID: "session-A", turnID: "1", taskID: "task-A",
                    attempt: 1, scopeID: "scope-A")),
                sequence: 3, occurredAt: Date(timeIntervalSince1970: 3),
                kind: .tool, status: .succeeded, summary: "旧终态",
                toolName: "file_read", toolCallID: "same-call",
                toolCompositeKey: a.compositeKey, receiptID: a.receiptID
            )
        ]).projectingRecoveredPendingTools(
            reloaded.recoveredPendingReceipts,
            activeExecutions: [], occurredAt: Date(timeIntervalSince1970: 4)
        )
        #expect(terminalButStillPending.toolLifecycleEvents.first {
            $0.identity.sessionID == "session-A"
        }?.status == .needsReview)
        let oldIdentity = try #require(base.toolLifecycleEvents.first?.identity)
        let closedTask = ConversationEventProjection(events: base.events + [
            ConversationEvent(
                id: "closed-task-A", identity: oldIdentity, sequence: 2,
                occurredAt: Date(timeIntervalSince1970: 2), kind: .task,
                status: .succeeded, summary: "旧任务已结束"
            )
        ]).projectingRecoveredPendingTools(
            reloaded.recoveredPendingReceipts,
            activeExecutions: [], occurredAt: Date(timeIntervalSince1970: 3)
        )
        #expect(closedTask.toolLifecycleEvents.first {
            $0.identity.sessionID == "session-A"
        }?.identity.taskID.hasPrefix("recovered-tool:") == true)
        #expect(reloaded.pendingReceipts.count == 2)
        #expect(reloaded.facts.isEmpty)
        #expect(try reloaded.settle(a, status: .succeeded)?.status == .succeeded)
        #expect(reloaded.pendingReceipts == [b])
    }
}
