import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-PERF-05 长草稿持久化")
@MainActor
struct P3AcceptanceM02_DraftPersistenceTests {
    private func makeStore() -> DraftStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m02-draft-persistence-\(UUID().uuidString)", isDirectory: true)
        let store = DraftStore(directory: directory)
        store.debounceInterval = .milliseconds(40)
        return store
    }

    private func longText(_ suffix: String) -> String {
        String(repeating: "长草稿内容", count: 1_000) + suffix
    }

    private func makeChat(store: DraftStore, suite: String) throws -> ChatStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: store.directory.appendingPathComponent("logs"))
        )
        chat.attachDraftStore(store)
        return chat
    }

    @Test func rapidLongEditsStayLocalUntilOnePersistenceBoundary() throws {
        let store = makeStore()
        let suite = "m02-draft-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let chat = try makeChat(store: store, suite: suite)
        let sessionID = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: sessionID)
        var transcriptChanges = 0
        chat.onSessionsChanged = { transcriptChanges += 1 }

        for index in 0..<80 {
            chat.draftText = longText("-\(index)")
        }
        let finalText = longText("-79")
        #expect(chat.draftText == finalText)
        // No full UTF-8 payload reaches DraftStore during the synchronous
        // typing burst, so it cannot create one write Task per keystroke.
        #expect(store.latestPayload(for: key) == nil)
        #expect(transcriptChanges == 0)
        #expect(chat.longDraftTimerCreationCount == 1)
        #expect(chat.longDraftEncodingCount == 0)

        #expect(chat.flushPendingDraftForTermination())
        #expect(chat.longDraftEncodingCount == 1)
        #expect(String(data: try #require(store.load(key: key)), encoding: .utf8) == finalText)
        #expect(transcriptChanges == 0)
    }

    @Test func sessionSwitchFlushesExactOldDraftWithoutWritingItToNewSession() throws {
        let store = makeStore()
        let suite = "m02-draft-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let chat = try makeChat(store: store, suite: suite)
        let first = try #require(chat.activeSessionID)
        let firstText = longText("-first")
        chat.draftText = firstText

        let second = chat.applyNewSession()
        #expect(second != first)
        #expect(chat.draftText.isEmpty)
        #expect(String(data: try #require(store.load(key: DraftStore.chatDraftKey(sessionID: first))),
                       encoding: .utf8) == firstText)

        let secondText = longText("-second")
        chat.draftText = secondText
        #expect(chat.applySwitchSession(id: first))
        #expect(chat.draftText == firstText)
        #expect(String(data: try #require(store.load(key: DraftStore.chatDraftKey(sessionID: second))),
                       encoding: .utf8) == secondText)
    }

    @Test func switchingToUnreadSessionPersistsItsReadState() throws {
        let drafts = makeStore()
        let suite = "m02-draft-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: drafts.directory)
        }
        let chat = try makeChat(store: drafts, suite: suite)
        let sessions = SessionStore(directory: drafts.directory.appendingPathComponent("chat"))
        try #require(chat.attachPersistence(sessions))
        let first = chat.applyNewSession()
        _ = chat.applyNewSession()
        chat.setUnread(true, sessionID: first)
        try #require(sessions.loadSession(id: first.uuidString)?.unread == true)
        chat.onSessionSelectionChanged = {}

        try #require(chat.applySwitchSession(id: first))

        let reopened = SessionStore(directory: sessions.directory)
        #expect(reopened.loadSession(id: first.uuidString)?.unread == false)
    }

    @Test func idleBoundaryPersistsLatestLongDraftWithoutAnExplicitFlush() async throws {
        let store = makeStore()
        let suite = "m02-draft-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let chat = try makeChat(store: store, suite: suite)
        let sessionID = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: sessionID)
        let finalText = longText("-idle")
        chat.draftText = longText("-earlier")
        chat.draftText = finalText

        // The deadline is only a test safety bound; the assertion is the
        // eventual final payload, not an implementation timing threshold.
        for _ in 0..<100 {
            if store.hasDraft(key: key) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(String(data: try #require(store.load(key: key)), encoding: .utf8) == finalText)
    }

    @Test func forkingAwayFromLongDraftFlushesItsOriginalSession() throws {
        let store = makeStore()
        let suite = "m02-draft-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let chat = try makeChat(store: store, suite: suite)
        let original = try #require(chat.activeSessionID)
        let finalText = longText("-before-fork")
        chat.draftText = finalText

        let fork = try #require(chat.applyDuplicateSession(id: original))
        #expect(fork != original)
        #expect(String(data: try #require(store.load(key: DraftStore.chatDraftKey(sessionID: original))),
                       encoding: .utf8) == finalText)
        #expect(chat.applySwitchSession(id: original))
        #expect(chat.draftText == finalText)
    }

    @Test func clearingLongDraftCancelsPendingSaveAndDoesNotResurrectOldText() throws {
        let store = makeStore()
        let suite = "m02-draft-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let chat = try makeChat(store: store, suite: suite)
        let sessionID = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: sessionID)
        chat.draftText = longText("-discard")
        chat.draftText = ""

        #expect(chat.flushPendingDraftForTermination())
        #expect(store.latestPayload(for: key) == nil)
        #expect(!store.hasDraft(key: key))
        #expect(chat.draftText.isEmpty)
    }

    @Test func sendingLongDraftClearsPendingAndPersistedText() throws {
        let store = makeStore()
        let suite = "m02-draft-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let chat = try makeChat(store: store, suite: suite)
        let sessionID = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: sessionID)
        chat.draftText = longText("-to-send")
        #expect(chat.flushPendingDraftForTermination())
        #expect(store.hasDraft(key: key))

        chat.sendDraft()
        #expect(chat.draftText.isEmpty)
        #expect(store.latestPayload(for: key) == nil)
        #expect(!store.hasDraft(key: key))
        chat.stopStreaming()
    }

    @Test func normalExitFlushesLatestLongDraftBeforeCleanMarker() throws {
        let store = makeStore()
        store.debounceInterval = .seconds(30)
        let suite = "m02-draft-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: store.directory.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(
                directory: store.directory.appendingPathComponent("session-documents")
            ),
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.chat.attachDraftStore(store)
        let sessionID = try #require(bridge.chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: sessionID)
        let lifecycle = AppLifecycleGuard(defaults: defaults)
        #expect(lifecycle.beginSession())
        let finalText = longText("-at-exit")
        bridge.chat.draftText = finalText
        #expect(!store.hasDraft(key: key))

        lifecycle.handleWillTerminate(bridge: bridge)
        #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey))
        let reopened = DraftStore(directory: store.directory)
        #expect(String(data: try #require(reopened.load(key: key)), encoding: .utf8) == finalText)
    }
}
