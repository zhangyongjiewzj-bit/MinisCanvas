import CryptoKit
import Foundation
import MinisCore

/// Owned multimedia starting data for a packaged-field journey. The UI operator
/// chooses a model and performs the actual send; this fixture never calls one.
enum MultimediaPackageFieldFixture {
    static let activationArgument = "--multimedia-field-fixture"
    static let sessionTitle = "M2397 两秒音视频与字幕"
    static let videoFileName = "media2397.mp4"
    private static let mediaDirectoryName = "multimedia-field-2397"
    private static let markerName = "multimedia-field-2397.json"
    private static let sourceSHA256 = "7610a76d58d291e438deeb412348771bd2841a7e9bbff9cea660e35dc48ae966"
    private static let subtitleText = "2397 owned caption"

    struct Receipt: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let sessionID: String
        let attachmentID: String
        let mediaFileRelativePath: String
        let videoSHA256: String
        let durationSeconds: Double
        let actualFrameTimecodes: [Double]
        let audioSHA256: String
        let audioStartSeconds: Double
        let audioEndSeconds: Double
        let subtitleCues: [MediaVideoSubtitleCue]
    }

    enum FixtureError: LocalizedError {
        case invalidFieldRoot
        case invalidSourceAsset
        case existingFixtureWithoutMarker
        case invalidMarker
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .invalidFieldRoot: "多媒体现场根或会话存储身份无效"
            case .invalidSourceAsset: "多媒体合成素材与固定来源校验不符"
            case .existingFixtureWithoutMarker: "现场已有同名素材或会话且无有效标记"
            case .invalidMarker: "多媒体夹具标记或已生成素材不匹配"
            case .extractionFailed: "实际视频抽帧、音轨或字幕未完整提取"
            }
        }
    }

    static func isRequested(
        profile: RuntimeIsolationProfile,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        let count = arguments.filter { $0 == activationArgument }.count
        guard count > 0 else { return false }
        precondition(count == 1, "Multimedia field fixture activation must be unique")
        precondition(profile.mode == .packagedField,
                     "Multimedia fixture requires a packaged-field profile")
        return true
    }

    /// Run before BridgeStore attaches this exact root SessionStore. The media
    /// file is copied from an immutable packaged asset, then the production
    /// AVFoundation extractor creates actual PNG/WAV/cue payloads. Restarting
    /// the same field root only verifies the marker and preserves UI changes.
    nonisolated static func prepare(
        profile: RuntimeIsolationProfile,
        store: SessionStore
    ) async throws -> Receipt {
        guard profile.mode == .packagedField,
              store.directory.resolvingSymlinksInPath().standardizedFileURL
                == profile.sessionDirectory.resolvingSymlinksInPath().standardizedFileURL,
              let permissions = try FileManager.default.attributesOfItem(
                atPath: profile.rootDirectory.path
              )[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o700 else {
            throw FixtureError.invalidFieldRoot
        }
        let mediaDirectory = profile.attachmentsDirectory.appendingPathComponent(
            mediaDirectoryName, isDirectory: true
        )
        let mediaFile = mediaDirectory.appendingPathComponent(videoFileName)
        let marker = profile.minisCanvasDirectory.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let receipt = try? JSONDecoder().decode(Receipt.self,
                    from: Data(contentsOf: marker)),
                  receipt.schemaVersion == 1,
                  receipt.videoSHA256 == sourceSHA256,
                  receipt.mediaFileRelativePath == "ChatAttachments/\(mediaDirectoryName)/\(videoFileName)",
                  store.loadSession(id: receipt.sessionID) != nil,
                  let bytes = try? Data(contentsOf: mediaFile),
                  digest(bytes) == receipt.videoSHA256 else {
                throw FixtureError.invalidMarker
            }
            return receipt
        }
        guard !FileManager.default.fileExists(atPath: mediaFile.path),
              !store.listSessions().contains(where: { $0.title == sessionTitle }) else {
            throw FixtureError.existingFixtureWithoutMarker
        }
        guard let packaged = MinisCanvasResourceBundle.current?.bundle.url(
            forResource: "media2397", withExtension: "mp4", subdirectory: "FieldFixtures"
        ), let bytes = try? Data(contentsOf: packaged),
              digest(bytes) == sourceSHA256 else {
            throw FixtureError.invalidSourceAsset
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: mediaDirectory,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: mediaFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: mediaFile.path)

        let source = try AVFoundationVideoFrameSource(fileURL: mediaFile)
        let attachment = await ChatStore.resolveVideoAttachment(
            id: UUID(), url: mediaFile, name: videoFileName,
            mime: "video/mp4", size: Int64(bytes.count), source: source
        )
        try Task.checkCancellation()
        let composed = ChatStore.composeUserContentWithOwnership(
            text: "请根据已附加的实际抽帧、音轨和字幕描述这段合成视频。",
            attachments: [attachment]
        )
        guard attachment.status == .ready,
              let frames = attachment.videoFrames, frames.count == 3,
              let context = attachment.videoContext,
              (1.95...2.05).contains(context.durationSeconds),
              context.audioState == .extracted,
              context.subtitleState == .extracted,
              let audio = context.audio, audio.data != nil,
              context.subtitles.contains(where: { $0.text == subtitleText }),
              frames.allSatisfy({ $0.pngData != nil }),
              let ownership = composed.ownership else {
            throw FixtureError.extractionFailed
        }
        let thread = ChatThread(title: sessionTitle, messages: [
            ChatMessageUI(role: .user, content: composed.content,
                attachments: [attachment], composedContentOwnership: ownership)
        ])
        let existingSessions = store.listSessions()
        guard existingSessions.allSatisfy({ UUID(uuidString: $0.id) != nil }) else {
            throw FixtureError.invalidFieldRoot
        }
        try Task.checkCancellation()
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(session: thread, to: store.directory)
        let receipt = Receipt(schemaVersion: 1,
            sessionID: thread.id.uuidString,
            attachmentID: attachment.id.uuidString,
            mediaFileRelativePath: "ChatAttachments/\(mediaDirectoryName)/\(videoFileName)",
            videoSHA256: sourceSHA256,
            durationSeconds: context.durationSeconds,
            actualFrameTimecodes: frames.map(\.timecodeSeconds),
            audioSHA256: audio.digest,
            audioStartSeconds: audio.startSeconds,
            audioEndSeconds: audio.endSeconds,
            subtitleCues: context.subtitles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Task.checkCancellation()
        try encoder.encode(receipt).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: marker.path)
        return receipt
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
