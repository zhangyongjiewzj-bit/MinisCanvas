import Foundation
import Testing
@testable import MinisCore

@Suite struct ChildInstructionMailboxTests {
    private func fixture() throws -> (AgentTaskStore, ChildTranscriptLocator, ParentRuntimeIdentity) {
        let store = AgentTaskStore()
        let parent = ParentRuntimeIdentity(sessionID: "mail-parent-session", conversationID: "mail-parent-session",
            turnID: "turn-handle:1", taskID: "mail-parent", actorID: "test")
        _ = try store.enqueue(taskID: "mail-child", parentID: parent.taskID, providerID: nil, modelID: nil,
            parentRuntimeIdentity: parent)
        _ = try store.startRun(taskID: "mail-child", parentID: parent.taskID, runID: "mail-run")
        let locator = ChildTranscriptLocator(childSessionID: "mail-child-session", parentSessionID: parent.sessionID,
            taskID: "mail-child", parentID: parent.taskID, runID: "mail-run", attemptID: "mail-run:attempt:1",
            childExecutionID: "mail-execution", parentContextSnapshotID: nil)
        _ = try store.bindChildTranscript(locator)
        return (store, locator, parent)
    }

    @Test func mailboxConsumesInOrderExactlyOnce() throws {
        let (store, locator, parent) = try fixture()
        #expect(try store.appendChildInstruction(locator: locator, source: parent, text: "first") == 1)
        #expect(try store.appendChildInstruction(locator: locator, source: parent, text: "second") == 2)
        #expect(store.childInstructionQueueSnapshot(locator: locator)?.state == .pending)
        #expect(try store.consumeChildInstructions(locator: locator) == ["first", "second"])
        #expect(try store.consumeChildInstructions(locator: locator).isEmpty)
        #expect(store.childInstructionQueueSnapshot(locator: locator)?.queuedCount == 0)
    }

    @Test func cancelledChildRetainsUndeliveredCountAndNeverReplays() throws {
        let (store, locator, parent) = try fixture()
        _ = try store.appendChildInstruction(locator: locator, source: parent, text: "pending")
        _ = try store.finish(runID: locator.runID, outcome: .cancelled)
        #expect(store.childInstructionQueueSnapshot(locator: locator)?.state == .endedWithoutDelivery)
        #expect(store.childInstructionQueueSnapshot(locator: locator)?.queuedCount == 1)
        #expect(throws: CancellationError.self) { try store.consumeChildInstructions(locator: locator) }
        #expect(throws: ChildInstructionMailboxError.staleAttempt) {
            try store.appendChildInstruction(locator: locator, source: parent, text: "late")
        }
    }

    @Test func foreignSourceAndOverflowCannotAlterMailbox() throws {
        let (store, locator, parent) = try fixture()
        let foreign = ParentRuntimeIdentity(sessionID: "other", conversationID: "other",
            turnID: parent.turnID, taskID: parent.taskID, actorID: parent.actorID)
        #expect(throws: ChildInstructionMailboxError.foreignSource) {
            try store.appendChildInstruction(locator: locator, source: foreign, text: "foreign")
        }
        #expect(throws: ChildInstructionMailboxError.invalidText) {
            try store.appendChildInstruction(locator: locator, source: parent, text: String(repeating: "x", count: 4_097))
        }
        for index in 0..<8 { _ = try store.appendChildInstruction(locator: locator, source: parent, text: "m\(index)") }
        #expect(throws: ChildInstructionMailboxError.full) {
            try store.appendChildInstruction(locator: locator, source: parent, text: "overflow")
        }
        #expect(store.childInstructionQueueSnapshot(locator: locator)?.queuedCount == 8)
    }

    @Test func nextIterationAddsUserMessageWithoutDispatchingTools() async throws {
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var taken = false
            func take() -> [String] {
                lock.lock(); defer { lock.unlock() }
                guard !taken else { return [] }
                taken = true
                return ["only explain the plan"]
            }
        }
        let inbox = Once()
        let provider = ScriptedChildProvider(responses: ["done"])
        var loop = AgentLoop(maxIterations: 1)
        loop.takeAdditionalChildInstructions = { inbox.take() }
        let result = try await loop.run(messages: [LLMMessage(role: .user, content: "initial")],
            systemPrompt: nil, provider: provider, toolExecutor: NoopToolExecutor(), tools: [])
        #expect(provider.receivedRequests.first?.last?.content == "[用户追加指令]\nonly explain the plan")
        #expect(result.toolCallsExecuted == 0)
    }
}
