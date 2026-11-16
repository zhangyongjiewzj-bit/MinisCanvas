import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SESSION-13 Finder session file boundary")
@MainActor
struct P3AcceptanceM06_SessionFinderRevealBoundaryTests {
    @Test("Finder target is a persisted active session file, never an unknown or linked path")
    func finderTargetRejectsUnknownMissingAndSymlinkFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSESSION13-Finder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chat = ChatStore()
        let bootstrapID = try #require(chat.activeSessionID)
        #expect(chat.finderRevealURL(bootstrapID) == nil)

        let store = SessionStore(directory: root)
        #expect(chat.attachPersistence(store))
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("合成会话内容")
        let file = store.sessionsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
        #expect(chat.finderRevealURL(sessionID) == file.standardizedFileURL)
        #expect(chat.finderRevealURL(UUID()) == nil)

        try FileManager.default.removeItem(at: file)
        #expect(chat.finderRevealURL(sessionID) == nil)

        let unrelated = root.appendingPathComponent("unrelated.json")
        try Data("synthetic".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: unrelated)
        #expect(chat.finderRevealURL(sessionID) == nil)
    }
}
