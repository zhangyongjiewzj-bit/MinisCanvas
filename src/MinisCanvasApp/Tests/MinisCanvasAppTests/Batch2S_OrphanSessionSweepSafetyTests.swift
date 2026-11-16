import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Orphan session sweep safety")
@MainActor
struct Batch2S_OrphanSessionSweepSafetyTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-sweep-\(UUID().uuidString)")
    }

    private func persisted(_ id: String, title: String) -> ChatSession {
        ChatSession(
            id: id,
            title: title,
            messages: [LLMMessage(role: .user, content: title)],
            modelID: "test-model",
            providerTypeRaw: "test-provider"
        )
    }

    private func file(_ store: SessionStore, _ id: String) -> URL {
        store.sessionsDirectory.appendingPathComponent("\(id).json")
    }

    @Test func sessionWrittenToDiskAfterLoadSurvivesSave() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let externalID = UUID().uuidString
        try store.updateSession(persisted(externalID, title: "external writer"))

        chat.newSession()
        chat.appendUser("trigger a normal save")

        #expect(FileManager.default.fileExists(atPath: file(store, externalID).path))
    }

    @Test func undecodableSessionFileSurvivesSave() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        try FileManager.default.createDirectory(
            at: store.sessionsDirectory, withIntermediateDirectories: true)
        let brokenURL = file(store, UUID().uuidString)
        try Data("not json".utf8).write(to: brokenURL)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))

        chat.newSession()
        chat.appendUser("trigger a normal save")

        #expect(FileManager.default.fileExists(atPath: brokenURL.path))
    }

    @Test func sessionDeletedInAppIsRemovedFromDisk() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        if chat.activeSessionID == nil { chat.newSession() }
        chat.appendUser("first")
        chat.newSession()
        let doomed = try #require(chat.activeSessionID)
        chat.appendUser("to be deleted")
        #expect(FileManager.default.fileExists(atPath: file(store, doomed.uuidString).path))

        let preview = try chat.previewCurrentDeletion(id: doomed)
        let confirmed = preview.intent
            .withFirstConfirmation("已核对这份预览").withSecondConfirmation("移入回收站")
        _ = try chat.deleteSession(id: doomed, intent: confirmed)
        chat.appendUser("another save")

        #expect(!FileManager.default.fileExists(atPath: file(store, doomed.uuidString).path))
    }

    @Test func lowercaseIDLoadedSessionSurvivesSave() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let lowerID = UUID().uuidString.lowercased()
        try store.updateSession(persisted(lowerID, title: "lowercase id"))
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))

        chat.newSession()
        chat.appendUser("trigger a normal save")

        #expect(store.loadSession(id: lowerID) != nil)
    }
}
