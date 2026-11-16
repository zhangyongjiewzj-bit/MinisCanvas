import Foundation
import Testing
@testable import MinisCore

@Suite("Scheduled transcript delivery facts")
struct ScheduledTranscriptDeliveryFactTests {
    @Test func canonicalCASPersistsFactWithTranscriptAndRejectsDuplicate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-delivery-cas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let initial = try store.createSession(projectID: "local-project")
        #expect(initial.scheduledTranscriptDeliveries.isEmpty)
        let fact = ScheduledTranscriptDelivery(occurrenceID: UUID(),
            effectID: "scheduler-effect:local", taskID: UUID(), taskVersion: 2,
            executionTurnID: 9, executionMessageID: UUID().uuidString)
        let replacement = [LLMMessage(role: .user, content: "local input"),
                           LLMMessage(role: .assistant, content: "local response")]
        let committed = try store.compareAndCommitTranscript(sessionID: initial.id,
            projectID: "local-project", expectedRevision: initial.transcriptRevision,
            expectedMessages: initial.messages, replacementMessages: replacement,
            scheduledDelivery: fact)
        #expect(committed.messages == replacement)
        #expect(committed.scheduledTranscriptDeliveries == [fact])
        let reopened = SessionStore(directory: root)
        let persisted = try #require(reopened.loadSession(id: initial.id))
        #expect(persisted.scheduledTranscriptDeliveries == [fact])
        #expect(throws: SessionStoreError.sessionSnapshotConflict(initial.id)) {
            try reopened.compareAndCommitTranscript(sessionID: initial.id,
                projectID: "local-project", expectedRevision: persisted.transcriptRevision,
                expectedMessages: persisted.messages, replacementMessages: replacement,
                scheduledDelivery: fact)
        }
        #expect(reopened.loadSession(id: initial.id) == persisted)
        var uiProjection = persisted
        uiProjection.title = "updated title"
        uiProjection.scheduledTranscriptDeliveries = []
        #expect(try reopened.updateSessionUnlessTranscriptIsNewer(uiProjection))
        let updated = try #require(reopened.loadSession(id: initial.id))
        #expect(updated.title == "updated title")
        #expect(updated.scheduledTranscriptDeliveries == [fact])

        var newProjection = ChatSession(id: UUID().uuidString)
        newProjection.scheduledTranscriptDeliveries = [fact]
        #expect(try reopened.updateSessionUnlessTranscriptIsNewer(newProjection))
        #expect(reopened.loadSession(id: newProjection.id)?.scheduledTranscriptDeliveries == [])

    }

    @Test func oldSessionWithoutFactKeyDecodesEmpty() throws {
        let original = ChatSession(id: UUID().uuidString)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "scheduledTranscriptDeliveries")
        let legacy = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.scheduledTranscriptDeliveries.isEmpty)
    }
}
