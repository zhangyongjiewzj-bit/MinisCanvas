import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-COMPOSER-05/08 right panel preview source", .serialized)
@MainActor
struct AttachmentRightPanel2478Tests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-panel-2478-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func settledPreview(in store: FileTreeStore) async -> FilePreview? {
        for _ in 0..<100 {
            if let preview = store.preview { return preview }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return store.preview
    }

    @Test("real FileTreeStore shows supported bytes but fails a removed video source")
    func validSourcesAndRemovedVideo() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTreeStore(rootURL: directory)
        let sessionID = UUID()

        let textURL = directory.appendingPathComponent("note.txt")
        try Data("owned text preview".utf8).write(to: textURL)
        store.selectAttachment(ChatAttachmentPreviewSelection(sessionID: sessionID, url: textURL))
        let textPreview = await settledPreview(in: store)
        #expect(textPreview?.text == "owned text preview")
        #expect(textPreview?.error == nil)

        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lGkAAAAASUVORK5CYII="))
        let imageURL = directory.appendingPathComponent("pixel.png")
        try png.write(to: imageURL)
        store.selectAttachment(ChatAttachmentPreviewSelection(sessionID: sessionID, url: imageURL))
        let imagePreview = await settledPreview(in: store)
        #expect(imagePreview?.imageData == png)
        #expect(imagePreview?.error == nil)

        // A source can disappear after the click's source check but before the
        // panel's detached preview read. This is the actual FileTreeStore path.
        let videoURL = directory.appendingPathComponent("removed.mp4")
        try Data("synthetic preview source".utf8).write(to: videoURL)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))
        try FileManager.default.removeItem(at: videoURL)
        store.selectAttachment(ChatAttachmentPreviewSelection(sessionID: sessionID, url: videoURL))
        let failedPreview = await settledPreview(in: store)
        #expect(failedPreview?.kind == .video)
        #expect(failedPreview?.videoURL == nil)
        #expect(failedPreview?.error != nil)

        let deniedURL = directory.appendingPathComponent("denied.mp4")
        try Data("synthetic preview source".utf8).write(to: deniedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: deniedURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deniedURL.path) }
        #expect(!FileManager.default.isReadableFile(atPath: deniedURL.path))
        store.selectAttachment(ChatAttachmentPreviewSelection(sessionID: sessionID, url: deniedURL))
        let deniedPreview = await settledPreview(in: store)
        #expect(deniedPreview?.videoURL == nil)
        #expect(deniedPreview?.error != nil)
    }

    @Test("retired chat preview cannot publish a late result into the next session")
    func removedSelectionDiscardsLateResult() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTreeStore(rootURL: directory)
        let textURL = directory.appendingPathComponent("session-a.txt")
        try Data("session A".utf8).write(to: textURL)
        let original = ChatAttachmentPreviewSelection(sessionID: UUID(), url: textURL)
        store.selectAttachment(original)
        store.clearChatAttachmentSelection()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.selectedURL == nil)
        #expect(store.preview == nil)
        #expect(store.canShowPreview(for: nil))
    }
}
