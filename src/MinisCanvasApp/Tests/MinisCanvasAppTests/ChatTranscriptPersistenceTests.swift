import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 chat transcript persistence consumer")
struct ChatTranscriptPersistenceTests {
    private func makeStore() throws -> (DraftStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3-transcript-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // DraftStore requires an existing root to be owner-only. Foundation's
        // default directory mode is 0755, which would make the empty fixture
        // look like a recovery-required store before the first persist.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let store = DraftStore(directory: root)
        store.debounceInterval = .seconds(30)
        return (store, root)
    }

    private func identity(
        sessionID: String = "session-1",
        turnID: String = "turn-1",
        streamID: String = "stream-1"
    ) throws -> ChatTranscriptIdentity {
        try ChatTranscriptIdentity(sessionID: sessionID, turnID: turnID, streamID: streamID)
    }

    @Test("raw responses are redacted before persistence")
    func redactsRawResponseAndKeepsTypedIdentity() throws {
        let redactor = ChatTranscriptRedactor(secretValues: ["fixture-secret-value"])
        let raw = "Authorization: Bearer fixture-secret-value; sk-abcdefghijklmnop"
        let redacted = ChatTranscriptFormatter.redactedRawResponse(raw, redactor: redactor)
        #expect(!redacted.contains("fixture-secret-value"))
        #expect(!redacted.contains("sk-abcdefghijklmnop"))
        let entry = redactor.redact(ChatTranscriptEntry(
            role: .assistant,
            text: raw
        ))
        #expect(!entry.text.contains("fixture-secret-value"))
        #expect(entry.role == .assistant)
    }

    @Test("duplicate, skipped and late stream writes are rejected")
    func sequenceFenceRejectsDuplicateAndLateWrites() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ChatTranscriptPersistence(draftStore: store)
        let id = try identity()
        let entries = [ChatTranscriptEntry(role: .assistant, text: "partial")]
        _ = try persistence.persist(identity: id, sequence: 0, terminal: false, entries: entries)
        #expect(throws: ChatTranscriptPersistenceError.duplicateWrite) {
            try persistence.persist(identity: id, sequence: 0, terminal: false, entries: entries)
        }
        #expect(throws: ChatTranscriptPersistenceError.lateWrite) {
            try persistence.persist(identity: id, sequence: 2, terminal: false, entries: entries)
        }
        _ = try persistence.persist(identity: id, sequence: 1, terminal: true, entries: entries)
        #expect(throws: ChatTranscriptPersistenceError.lateWrite) {
            try persistence.persist(identity: id, sequence: 2, terminal: false, entries: entries)
        }
    }

    @Test("reopen recovers the durable redacted envelope and permits the next turn")
    func reopenRecoveryAndTurnRotation() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let redactor = ChatTranscriptRedactor(secretValues: ["fixture-secret-value"])
        let first = ChatTranscriptPersistence(draftStore: store, redactor: redactor)
        let id = try identity()
        _ = try first.persist(
            identity: id,
            sequence: 0,
            terminal: true,
            entries: [ChatTranscriptEntry(role: .assistant, text: "fixture-secret-value")]
        )

        let reopened = ChatTranscriptPersistence(
            draftStore: DraftStore(directory: root),
            redactor: ChatTranscriptRedactor(secretValues: [])
        )
        let envelope = try #require(try reopened.reopen(sessionID: "session-1"))
        #expect(envelope.identity == id)
        #expect(envelope.sequence == 0)
        #expect(envelope.terminal)
        #expect(!envelope.entries[0].text.contains("fixture-secret-value"))
        let nextID = try identity(turnID: "turn-2", streamID: "stream-2")
        _ = try reopened.persist(
            identity: nextID,
            sequence: 0,
            terminal: false,
            entries: [ChatTranscriptEntry(role: .user, text: "next")]
        )
        #expect(try reopened.reopen(sessionID: "session-1")?.identity == nextID)
    }

    @Test("reopen exposes resumable and recovery-required consumer states")
    func reopenConsumerProjection() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ChatTranscriptPersistence(
            draftStore: store,
            redactor: ChatTranscriptRedactor(secretValues: ["fixture-secret-value"])
        )
        let id = try identity()
        _ = try persistence.persist(
            identity: id,
            sequence: 0,
            terminal: false,
            entries: [ChatTranscriptEntry(role: .assistant, text: "fixture-secret-value")]
        )

        let resumable = persistence.reopenProjection(sessionID: "session-1")
        #expect(resumable.state == .resumeRequired)
        #expect(resumable.recoveryAction == .resume)
        #expect(resumable.isActionable)
        #expect(resumable.entries.first?.text != "fixture-secret-value")

        // An unsafe session key cannot become a path escape or a silent empty
        // transcript; the consumer exposes a safe reopen/discard decision.
        let recovery = persistence.reopenProjection(sessionID: "../unsafe")
        #expect(recovery.state == .recoveryRequired)
        #expect(recovery.recoveryAction == .reopenOrDiscard)
        #expect(recovery.message.contains("重新打开"))
    }

    @Test("identity conflicts expose an actionable recovery instruction")
    func identityConflictAction() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ChatTranscriptPersistence(draftStore: store)
        let first = try identity()
        let second = try identity(turnID: "turn-2", streamID: "stream-2")
        _ = try persistence.persist(
            identity: first,
            sequence: 0,
            terminal: false,
            entries: [ChatTranscriptEntry(role: .assistant, text: "in flight")]
        )
        #expect(throws: ChatTranscriptPersistenceError.identityConflict) {
            try persistence.persist(
                identity: second,
                sequence: 0,
                terminal: false,
                entries: [ChatTranscriptEntry(role: .assistant, text: "late")]
            )
        }
        #expect(ChatTranscriptPersistenceError.recoveryRequired.userAction.contains("重新打开"))
    }

    @Test("non-active Bridge rename survives ChatStore persistence reopen")
    @MainActor
    func productionRenameOfNonActiveSessionPersistsAcrossReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3-rename-persistence-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MinisCore.SessionStore(directory: root)
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        #expect(bridge.chat.attachPersistence(store))
        let originalID = try #require(bridge.chat.activeSessionID)

        let newObservation = try bridge.performSessionAction(.new(title: "活动会话"))
        let activeID = try #require(bridge.chat.activeSessionID)
        #expect(newObservation.receipt.action == .new)
        #expect(activeID != originalID)

        bridge.chat.draftText = "活动会话草稿"
        bridge.chat.appendUser("活动会话内容")
        let renameObservation = try bridge.performSessionAction(
            .rename(sessionID: originalID.uuidString, title: "非活动会话新标题")
        )
        #expect(renameObservation.receipt.action == .rename)
        #expect(renameObservation.receipt.sessionID == originalID.uuidString)
        #expect(bridge.chat.activeSessionID == activeID)
        #expect(bridge.chat.draftText == "活动会话草稿")
        #expect(
            bridge.chat.sessions.first(where: { $0.id == originalID })?.title
                == "非活动会话新标题"
        )
        #expect(bridge.chat.sessions.first(where: { $0.id == activeID })?.title == "活动会话")

        let reopened = ChatStore()
        #expect(reopened.attachPersistence(store))
        let restoredOriginal = try #require(
            reopened.sessions.first(where: { $0.id == originalID })
        )
        let restoredActive = try #require(
            reopened.sessions.first(where: { $0.id == activeID })
        )
        #expect(restoredOriginal.title == "非活动会话新标题")
        #expect(restoredActive.title == "活动会话")
        #expect(restoredActive.messages.contains { $0.content == "活动会话内容" })
    }
}
