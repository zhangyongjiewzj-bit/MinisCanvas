import Foundation
import Testing
@testable import MinisCore

@Suite("Compaction canonical fact capture")
struct CompactionFactCaptureTests {
    @Test func captureExcludesForeignSessionAndRequiresFullReceiptIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-fact-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        for session in ["source", "foreign"] {
            let identity = AgentExecutionIdentity(turn: .init(sessionID: session, turnID: 2,
                messageID: "message"), operationID: "operation", attempt: 1)
            let receipt = try ledger.mint(toolCallID: "same-call", toolName: "file_read",
                attemptID: "attempt", attemptNumber: 1, executionIdentity: identity)
            _ = try ledger.settle(receipt, status: .succeeded)
        }
        let messages = [LLMMessage(role: .user, content: "Continue safely")]
        let facts = CompactionFactCapture.capture(sessionID: "source", revision: 7,
            messages: messages, taskStore: nil, effectLedger: ledger)
        #expect(facts.count == 1)
        let source = try #require(facts.first?.source)
        #expect(source.sessionID == "source")
        #expect(source.transcriptRevision == 7)
        #expect(source.matchesTranscript(messages))
        #expect(!source.matchesTranscript([.init(role: .user, content: "changed source")]))
        #expect(CompactionFactCapture.verifyStores(facts, taskStore: nil,
            effectLedger: ledger, atCommit: true))
        #expect(!CompactionFactCapture.verifyStores(facts, taskStore: nil,
            effectLedger: ToolExecutionFactLedger(), atCommit: false))
        let background = try #require(CompactionFactCapture.backgroundMessage(facts))
        #expect(background.toolCalls.isEmpty)
        #expect(background.toolCallID == nil)
        #expect(background.content.contains("No authorization"))
        #expect(background.content.contains("Do not replay"))
        #expect(ledger.facts.count == 2)
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test func taskLocatorRequiresCompleteParentAndSessionBinding() {
        func task(parentSession: String, parent: String) -> AgentTaskSnapshot {
            AgentTaskSnapshot(taskID: "child", parentID: "parent", parentContextSnapshotID: "binding",
                providerID: nil, modelID: nil, configurationFingerprint: nil, routeReceiptID: nil,
                status: .running, childTranscriptLocator: .init(childSessionID: "child-session",
                    parentSessionID: parentSession, taskID: "child", parentID: parent,
                    runID: "run", attemptID: "attempt", childExecutionID: "execution",
                    parentContextSnapshotID: "binding"))
        }
        #expect(CompactionFactCapture.taskBelongs(task(parentSession: "source", parent: "parent"), to: "source"))
        #expect(!CompactionFactCapture.taskBelongs(task(parentSession: "foreign", parent: "parent"), to: "source"))
        #expect(!CompactionFactCapture.taskBelongs(task(parentSession: "source", parent: "foreign-parent"), to: "source"))
    }

    @Test func arbitraryTaskParentDoesNotEstablishSourceSession() throws {
        let tasks = AgentTaskStore()
        _ = try tasks.enqueue(taskID: "guess", parentID: "source", providerID: nil, modelID: nil)
        #expect(CompactionFactCapture.capture(sessionID: "source", revision: 1,
            messages: [.init(role: .user, content: "Continue")], taskStore: tasks,
            effectLedger: nil).isEmpty)
    }
}
