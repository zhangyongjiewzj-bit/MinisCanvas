import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-OUTPUT-05 canonical tool-summary page consumer")
struct P3AcceptanceM04_OutputPaginationConsumerTests {
    @Test("older tool facts load in bounded pages without crossing viewer sessions")
    func canonicalToolSummariesLoadOnlyOnRequest() throws {
        let eventsA = try makeToolEvents(sessionID: "session-A", count: 95)
        let eventsB = try makeToolEvents(sessionID: "session-B", count: 3)
        var paging = ChatInspectorToolEventPageState()

        let firstA = paging.page(sessionID: "session-A", events: eventsA, pageSize: 40)
        #expect(firstA.events.map(\.id) == eventsA.suffix(40).map(\.id))
        #expect(firstA.omittedCount == 55)
        #expect(firstA.visiblePageCount == 1)
        #expect(firstA.totalPages == 3)

        let staleRequest = paging.loadOlderIfCurrent(
            viewerSessionID: "session-A", activeSessionID: "session-B",
            canonicalEvents: eventsA + eventsB, pageSize: 40
        )
        #expect(!staleRequest)
        #expect(paging.page(sessionID: "session-A", events: eventsA, pageSize: 40) == firstA)
        let acceptedRequest = paging.loadOlderIfCurrent(
            viewerSessionID: "session-A", activeSessionID: "session-A",
            canonicalEvents: eventsA + eventsB, pageSize: 40
        )
        #expect(acceptedRequest)
        let secondA = paging.page(sessionID: "session-A", events: eventsA, pageSize: 40)
        #expect(secondA.events.map(\.id) == eventsA.suffix(80).map(\.id))
        #expect(secondA.omittedCount == 15)

        let firstB = paging.page(sessionID: "session-B", events: eventsB, pageSize: 40)
        #expect(firstB.events.map(\.id) == eventsB.map(\.id))
        #expect(firstB.omittedCount == 0)
        #expect(firstB.visiblePageCount == 1)

        paging.loadOlder(sessionID: "session-A", events: eventsA, pageSize: 40)
        let fullA = paging.page(sessionID: "session-A", events: eventsA, pageSize: 40)
        #expect(fullA.events.map(\.id) == eventsA.map(\.id))
        #expect(fullA.omittedCount == 0)
        paging.loadOlder(sessionID: "session-A", events: eventsA, pageSize: 40)
        #expect(paging.page(sessionID: "session-A", events: eventsA, pageSize: 40) == fullA)
        #expect(paging.page(sessionID: "session-B", events: eventsB, pageSize: 40) == firstB)
    }

    @Test("an older large result stays statistical after its page is requested")
    func loadedOlderPageNeverContainsRawToolResult() throws {
        let canary = "synthetic-private-output-page-canary"
        let raw = String(repeating: "safe row\n", count: 2_000) + canary
        let summary = ToolOutputSummary.capture(toolName: "shell_execute", output: raw)
        let candidateIdentity: MinisCore.ConversationEventIdentity? = .init(
            sessionID: "session-large", turnID: "synthetic-turn",
            taskID: "synthetic-task", attempt: 1, scopeID: "synthetic-scope"
        )
        let identity = try #require(candidateIdentity)
        let older = MinisCore.ConversationEvent(
            id: "older-large-result", identity: identity, sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 0),
            kind: .tool, status: .succeeded, summary: "工具结果正文已隐藏",
            toolName: "shell_execute", outputSummary: summary
        )
        let events = [older] + (try makeToolEvents(sessionID: "session-large", count: 80))
        var paging = ChatInspectorToolEventPageState()
        let first = paging.page(sessionID: "session-large", events: events, pageSize: 40)
        #expect(first.omittedCount == 41)
        #expect(!first.events.contains { $0.id == older.id })

        for _ in 0..<2 {
            let loaded = paging.loadOlderIfCurrent(
                viewerSessionID: "session-large", activeSessionID: "session-large",
                canonicalEvents: events, pageSize: 40
            )
            #expect(loaded)
        }
        let full = paging.page(sessionID: "session-large", events: events, pageSize: 40)
        let restoredOlder = try #require(full.events.first)
        #expect(restoredOlder.id == older.id)
        let visible = ToolEventCard.displayModel(for: restoredOlder)
        #expect(visible.summary.contains("返回 \(raw.utf8.count) 字节"))
        #expect(!visible.summary.contains(canary))
        #expect(!visible.accessibilityLabel.contains(canary))
        #expect(!String(decoding: try JSONEncoder().encode(full.events), as: UTF8.self).contains(canary))
    }

    private func makeToolEvents(sessionID: String, count: Int) throws -> [MinisCore.ConversationEvent] {
        let candidateIdentity: MinisCore.ConversationEventIdentity? = .init(
            sessionID: sessionID, turnID: "synthetic-turn",
            taskID: "synthetic-task", attempt: 1, scopeID: "synthetic-scope"
        )
        let identity = try #require(candidateIdentity)
        return (0..<count).map { index in
            MinisCore.ConversationEvent(
                id: "\(sessionID)-tool-\(index)",
                identity: identity,
                sequence: Int64(index + 1),
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                kind: .tool, status: .succeeded,
                summary: "工具摘要 \(index)",
                toolName: "synthetic-tool"
            )
        }
    }
}
