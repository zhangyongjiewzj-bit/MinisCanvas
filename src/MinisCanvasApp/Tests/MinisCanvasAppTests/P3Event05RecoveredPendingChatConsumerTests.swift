import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("EVENT5 recovered pending Chat consumer")
@MainActor
struct P3Event05RecoveredPendingChatConsumerTests {
    @Test("App shows proven no-dispatch separately and backfills a settled exact fact")
    func strictFileWriteRecoveryProjection() async throws {
        let profile = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = profile.rootDirectory.appendingPathComponent("event5-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factURL = root.appendingPathComponent("facts.json")
        let eventURL = root.appendingPathComponent("events.json")
        let first = try ToolExecutionFactLedger(persistenceURL: factURL)
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "event5-app-session", turnID: 1, messageID: "event5-app-message"),
            operationID: "event5-app-operation", attempt: 1)
        let unstarted = try first.mint(toolCallID: "unstarted", toolName: "file_write",
            attemptID: "app-attempt", attemptNumber: 1, executionIdentity: identity)
        try first.prepareFileWrite(unstarted)
        let settled = try first.mint(toolCallID: "settled", toolName: "file_write",
            attemptID: "app-attempt", attemptNumber: 1, executionIdentity: identity)
        let reopened = try ToolExecutionFactLedger(persistenceURL: factURL)
        _ = try reopened.settle(settled, status: .succeeded)
        let suite = "event5-app-\(UUID().uuidString)"
        let chat = ChatStore(preferencesDefaults: UserDefaults(suiteName: suite),
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        try chat.attachToolLifecyclePersistence(eventURL)
        chat.agentEngine = AgentLoopChatEngine(toolExecutionFactLedger: reopened)
        let pending = try #require(chat.conversationEventProjection.toolLifecycleEvents.first {
            $0.toolCompositeKey == unstarted.compositeKey
        })
        #expect(pending.status == .needsReview)
        #expect(pending.summary.contains("未执行"))
        #expect(pending.summary.contains("用户确认"))
        await chat.reconcileRecoveredFileWrites(
            using: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []), ledger: reopened)
        let rows = chat.conversationEventProjection.toolLifecycleEvents
        #expect(rows.first { $0.toolCompositeKey == settled.compositeKey }?.status == .succeeded)
        #expect(rows.first { $0.toolCompositeKey == unstarted.compositeKey }?.status == .needsReview)
        #expect(reopened.pendingReceipts == [unstarted])
        #expect(reopened.facts.first?.receiptID == settled.receiptID)
    }

    @Test("restart projects pending as review, keeps live call running, and never masks a later terminal")
    func restartProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("event05-chat-\(UUID().uuidString)", isDirectory: true)
        let suite = "event05-chat-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factURL = root.appendingPathComponent("tool-execution-facts-v4.json")
        let eventURL = root.appendingPathComponent("tool-lifecycle-events-v1.json")
        let first = try ToolExecutionFactLedger(persistenceURL: factURL)
        let aIdentity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-A", turnID: 1, messageID: "message-A"),
            operationID: "operation-A", attempt: 1
        )
        let bIdentity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-B", turnID: 1, messageID: "message-B"),
            operationID: "operation-B", attempt: 1
        )
        let a = try first.mint(toolCallID: "same-call", toolName: "file_read",
            attemptID: "attempt-A", attemptNumber: 1, executionIdentity: aIdentity)
        let b = try first.mint(toolCallID: "same-call", toolName: "file_read",
            attemptID: "attempt-B", attemptNumber: 1, executionIdentity: bIdentity)
        let aKey = try #require(a.compositeKey)
        let eventWriter = try ToolLifecycleConsumer(persistenceURL: eventURL)
        #expect(await eventWriter.ingestToolExecutionPhase(
            ToolExecutionPhaseFact(compositeKey: aKey,
                executionIdentity: aIdentity, toolName: "file_read", phase: .running,
                occurredAt: Date(timeIntervalSince1970: 1)),
            eventID: "same-call", eventName: "file_read", taskID: "task-A",
            expectedAttemptID: "attempt-A", scopeID: "scope-A"
        ))

        let reloaded = try ToolExecutionFactLedger(persistenceURL: factURL)
        let chat = ChatStore(
            preferencesDefaults: UserDefaults(suiteName: suite),
            logManager: LogManager(directory: root.appendingPathComponent("logs", isDirectory: true))
        )
        try chat.attachToolLifecyclePersistence(eventURL)
        chat.agentEngine = AgentLoopChatEngine(toolExecutionFactLedger: reloaded)
        var rows = chat.conversationEventProjection.toolLifecycleEvents
        #expect(rows.count == 2)
        #expect(rows.first { $0.identity.sessionID == "session-A" }?.status == .needsReview)
        #expect(rows.first { $0.identity.sessionID == "session-A" }?.identity.taskID == "task-A")
        #expect(rows.first { $0.identity.sessionID == "session-B" }?.status == .needsReview)
        #expect(rows.first { $0.identity.sessionID == "session-B" }?.identity.taskID.hasPrefix("recovered-tool:") == true)
        #expect(rows.allSatisfy { $0.approvalDecision == nil && $0.receiptID == nil })
        #expect(reloaded.pendingReceipts.count == 2)
        #expect(reloaded.facts.isEmpty)

        let liveIdentity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-C", turnID: 1, messageID: "message-C"),
            operationID: "operation-C", attempt: 1
        )
        let live = try reloaded.mint(toolCallID: "live-call", toolName: "file_read",
            attemptID: "attempt-C", attemptNumber: 1, executionIdentity: liveIdentity)
        let liveKey = try #require(live.compositeKey)
        #expect(await chat.ingestToolExecutionPhase(
            ToolExecutionPhaseFact(compositeKey: liveKey,
                executionIdentity: liveIdentity, toolName: "file_read", phase: .running,
                occurredAt: Date(timeIntervalSince1970: 2)),
            eventID: "live-call", eventName: "file_read", taskID: "task-C",
            expectedAttemptID: "attempt-C"
        ))
        rows = chat.conversationEventProjection.toolLifecycleEvents
        #expect(rows.first { $0.identity.sessionID == "session-C" }?.status == .running)
        #expect(reloaded.recoveredPendingReceipts.count == 2)

        let settled = try reloaded.settle(a, status: .succeeded)
        let fact = try #require(settled)
        let settledWriter = try ToolLifecycleConsumer(persistenceURL: eventURL)
        #expect(await settledWriter.ingestToolExecutionFact(
            fact, eventID: "same-call", eventName: "file_read", taskID: "task-A",
            expectedAttemptID: "attempt-A", scopeID: "scope-A"
        ))
        try chat.attachToolLifecyclePersistence(eventURL)
        rows = chat.conversationEventProjection.toolLifecycleEvents
        #expect(rows.first { $0.identity.sessionID == "session-A" }?.status == .succeeded)
        #expect(rows.first { $0.identity.sessionID == "session-B" }?.status == .needsReview)
        #expect(rows.first { $0.identity.sessionID == "session-C" }?.status == .running)
        #expect(reloaded.pendingReceipts.contains(b))
        #expect(!reloaded.pendingReceipts.contains(a))
    }
}
