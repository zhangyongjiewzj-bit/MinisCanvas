import Foundation
import Testing
@testable import MinisCore

@Suite("Agent runtime durable identity contracts")
struct AgentRuntimeDurabilityTests {
    @Test("writeback tombstone survives restart and rejects late re-admission")
    func writebackTombstoneSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-writeback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("writeback.json")
        let identity = AgentTurnIdentity(
            sessionID: "session-a",
            turnID: 1,
            messageID: "assistant-a"
        )

        let first = AgentTurnWritebackRegistry(persistenceURL: journal)
        #expect(await first.begin(identity))
        #expect(await first.cancel(identity))

        let restarted = AgentTurnWritebackRegistry(persistenceURL: journal)
        #expect(await restarted.accepts(identity) == false)
        #expect(await restarted.begin(identity) == false)
    }

    @Test("corrupt writeback journal fails closed")
    func corruptJournalFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-writeback-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("writeback.json")
        let corruptJournalData = Data("not-json".utf8)
        try corruptJournalData.write(to: journal, options: .atomic)

        let identity = AgentTurnIdentity(
            sessionID: "session-a",
            turnID: 1,
            messageID: "assistant-a"
        )
        let registry = AgentTurnWritebackRegistry(persistenceURL: journal)
        #expect(await registry.begin(identity) == false)
        await registry.reset()
        let dataAfterReset = try Data(contentsOf: journal)
        #expect(dataAfterReset == corruptJournalData)

        let restarted = AgentTurnWritebackRegistry(persistenceURL: journal)
        #expect(await restarted.begin(identity) == false)
    }

    @Test("budget reset invalidates a pre-reset provider lease")
    func budgetResetInvalidatesOldLease() async throws {
        let tracker = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 2,
            maxTokensPerSession: 100,
            overBudgetPolicy: .pause
        ))
        let lease = try await tracker.beginRequest()
        await tracker.reset()
        _ = await tracker.completeRequest(
            lease,
            usage: LLMUsage(inputTokens: 10, outputTokens: 10)
        )
        let budget = await tracker.budget
        #expect(await tracker.pendingRequestCount == 0)
        #expect(budget.usedRequests == 0)
        #expect(budget.usedTokens == 0)
    }

    @Test("compact remains local and does not mint a second turn identity")
    func compactContractIsAlreadyBoundToOneTurn() throws {
        let source = try source("Sources/MinisCore/Agent/AgentLoop.swift")
        #expect(source.contains("var didAutoCompact = false"))
        #expect(source.contains("didAutoCompact = true"))
        // C-L2 moved the compaction call into attemptContextCompaction, which returns the messages.
        #expect(source.contains("messages = compacted"))
        #expect(source.contains("turn: AgentTurnIdentity"))
    }

    private func source(_ relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
