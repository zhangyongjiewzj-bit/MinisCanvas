import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Multimedia package field fixture 2397")
struct MultimediaPackageFieldFixture2397Tests {
    @Test("actual AVFoundation media persists as canonical owned video, audio and subtitle")
    func createsAndReopensActualMediaSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "media-field-2397-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "media-field-2397",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                MultimediaPackageFieldFixture.activationArgument]
        )
        defer { try? profile.cleanupDisposableRoots() }
        #expect(MultimediaPackageFieldFixture.isRequested(profile: profile,
            arguments: [MultimediaPackageFieldFixture.activationArgument]))
        #expect(!MultimediaPackageFieldFixture.isRequested(profile: profile, arguments: []))

        let store = SessionStore(directory: profile.sessionDirectory)
        let neighbor = ChatSession(title: "other field producer")
        try store.updateSession(neighbor)
        let receipt = try await MultimediaPackageFieldFixture.prepare(profile: profile, store: store)
        #expect(receipt.schemaVersion == 1)
        #expect(receipt.durationSeconds >= 1.95 && receipt.durationSeconds <= 2.05)
        #expect(receipt.actualFrameTimecodes.count == 3)
        #expect(Set(receipt.actualFrameTimecodes).count == 3)
        #expect(receipt.audioEndSeconds > 1.8)
        #expect(receipt.subtitleCues.contains { $0.text == "2397 owned caption" })
        let media = profile.sessionDirectory.appendingPathComponent(receipt.mediaFileRelativePath)
        #expect(FileManager.default.fileExists(atPath: media.path))
        let reopenedStore = SessionStore(directory: profile.sessionDirectory)
        let persisted = try #require(reopenedStore.loadSession(id: receipt.sessionID))
        #expect(persisted.title == MultimediaPackageFieldFixture.sessionTitle)
        #expect(reopenedStore.loadSession(id: neighbor.id) == neighbor)
        let records = try ChatAttachmentPersistence.load(forSessionID: receipt.sessionID, from: reopenedStore.directory)
        let restored = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: records)
        let user = try #require(restored.messages.first)
        let attachment = try #require(user.attachments.first)
        #expect(attachment.id.uuidString == receipt.attachmentID)
        #expect(attachment.status == .ready)
        #expect(attachment.videoFrames?.map(\.timecodeSeconds) == receipt.actualFrameTimecodes)
        #expect(attachment.videoContext?.audio?.digest == receipt.audioSHA256)
        #expect(attachment.videoContext?.subtitles == receipt.subtitleCues)
        #expect(user.content.contains("2397 owned caption"))
        let request = user.asLLMMessage()
        #expect(request.images.count == 3)
        #expect(request.audios.count == 1)
        #expect(request.audios.first?.format == "wav")

        try reopenedStore.renameSession(id: receipt.sessionID, title: "kept UI change")
        let second = try await MultimediaPackageFieldFixture.prepare(profile: profile,
            store: reopenedStore)
        #expect(second == receipt)
        #expect(reopenedStore.loadSession(id: receipt.sessionID)?.title == "kept UI change")
        #expect(reopenedStore.listSessions().count == 2)
    }

    @Test("existing same-title session without marker is never overwritten")
    func refusesUnmarkedExistingSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "media-field-2397-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "media-field-2397",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                MultimediaPackageFieldFixture.activationArgument]
        )
        defer { try? profile.cleanupDisposableRoots() }
        let store = SessionStore(directory: profile.sessionDirectory)
        let existing = ChatSession(title: MultimediaPackageFieldFixture.sessionTitle)
        try store.updateSession(existing)
        await #expect(throws: MultimediaPackageFieldFixture.FixtureError.self) {
            try await MultimediaPackageFieldFixture.prepare(profile: profile, store: store)
        }
        #expect(store.loadSession(id: existing.id) == existing)
    }
}
