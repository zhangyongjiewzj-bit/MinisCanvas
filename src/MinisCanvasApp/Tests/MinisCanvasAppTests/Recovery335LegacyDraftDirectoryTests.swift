import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Recovery335 legacy owned draft directory")
@MainActor
struct Recovery335LegacyDraftDirectoryTests {
    @Test("unsent text saves privately and recovers after an owned legacy child directory is reopened")
    func ownedLegacyChildPersistsAndRecoversOriginalSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery335-\(UUID().uuidString)", isDirectory: true)
        let suite = "recovery335-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let draftRoot = root.appendingPathComponent("draft-store", isDirectory: true)
        let drafts = DraftStore(directory: draftRoot)
        drafts.debounceInterval = .seconds(30)
        try FileManager.default.createDirectory(at: drafts.draftsDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: draftRoot.path)
        // The historical Foundation writer created this same-owner child
        // with default0755. Do not weaken the final private-directory contract.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drafts.draftsDirectory.path)
        let writer = ChatStore(preferencesDefaults: defaults,
                               logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let sessionDirectory = root.appendingPathComponent("sessions")
        #expect(writer.attachPersistence(SessionStore(directory: sessionDirectory)))
        writer.attachDraftStore(drafts)
        let original = try #require(writer.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: original)
        defer {
            for session in writer.sessions { drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id)) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let text = "原会话未发送的335正文"
        writer.draftText = text
        #expect(writer.draftText == text)
        let saved = drafts.flushNow(key: key)
        #expect(saved, "owned legacy child must tighten permissions and save, not lose the accepted draft")
        guard saved else { return } // Preserve one exact RED at the failing seam.
        #expect(drafts.lastIOError(for: key) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: drafts.draftsDirectory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(String(data: try #require(drafts.load(key: key)), encoding: .utf8) == text)

        let other = writer.applyNewSession()
        #expect(writer.draftText.isEmpty)
        let reader = ChatStore(preferencesDefaults: defaults,
                               logManager: LogManager(directory: root.appendingPathComponent("reader-logs")))
        #expect(reader.attachPersistence(SessionStore(directory: sessionDirectory)))
        let reopened = DraftStore(directory: draftRoot)
        reopened.debounceInterval = .seconds(30)
        reader.attachDraftStore(reopened)
        defer {
            for session in reader.sessions { reopened.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id)) }
        }
        #expect(reader.applySwitchSession(id: original))
        #expect(reader.draftText == text)
        #expect(reader.applySwitchSession(id: other))
        #expect(reader.draftText.isEmpty)
        #expect(reader.applySwitchSession(id: original))
        #expect(reader.draftText == text)
        #expect(!reader.isStreaming && !writer.isStreaming)
    }

    @Test("reading an owned0755 child does not repair permissions or expose its payload")
    func pureReadKeepsLegacyChildStrict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery335-read-\(UUID().uuidString)", isDirectory: true)
        let seed = DraftStore(directory: root)
        seed.debounceInterval = .seconds(30)
        let key = "read-boundary"
        let payload = Data("strict read boundary".utf8)
        defer {
            seed.cancelPending(key: key)
            try? FileManager.default.removeItem(at: root)
        }
        seed.scheduleSave(key: key, payload: payload)
        #expect(seed.flushNow(key: key))
        let file = seed.draftsDirectory.appendingPathComponent("\(key).json")
        let committed = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: seed.draftsDirectory.path)

        let reader = DraftStore(directory: root)
        #expect(reader.load(key: key) == nil)
        #expect(reader.lastLoadError(for: key) == .decodeFailed)
        #expect(reader.lastIOError(for: key) == .unsafe)
        #expect(reader.draftKeys().isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: seed.draftsDirectory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try Data(contentsOf: file) == committed)
    }

    @Test("write hardening refuses child symlinks and non-directories", arguments: ["symlink", "regular-file"])
    func invalidChildStillFailsClosed(kind: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery335-invalid-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = root.appendingPathComponent("store", isDirectory: true)
        let store = DraftStore(directory: draftRoot)
        store.debounceInterval = .seconds(30)
        let key = "invalid-child"
        let target = root.appendingPathComponent("target", isDirectory: true)
        let sentinel = Data("untouched invalid child".utf8)
        defer {
            store.cancelPending(key: key)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: draftRoot.path)
        if kind == "symlink" {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: store.draftsDirectory, withDestinationURL: target)
        } else {
            try sentinel.write(to: store.draftsDirectory)
        }

        store.scheduleSave(key: key, payload: Data("must not escape".utf8))
        #expect(!store.flushNow(key: key))
        #expect(store.lastIOError(for: key) == .unsafe)
        if kind == "symlink" {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.draftsDirectory.path) == target.path)
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        } else {
            #expect(try Data(contentsOf: store.draftsDirectory) == sentinel)
        }
    }
}
