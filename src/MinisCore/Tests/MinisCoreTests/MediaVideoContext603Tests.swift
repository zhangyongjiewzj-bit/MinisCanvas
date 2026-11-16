import CryptoKit
import Foundation
import Testing
@testable import MinisCore

@Suite("Video603 local embedded audio/subtitle production adapter")
struct MediaVideoContext603Tests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/video603-av-caption.mp4")
    }

    @Test func actualEmbeddedAudioAndSubtitlesAreBoundedAndReachWireHistory() async throws {
        let bytes = try Data(contentsOf: fixture)
        #expect(bytes.count == 7127)
        let source = try AVFoundationVideoFrameSource(fileURL: fixture)
        let context = try #require(await source.supplementaryContext(maxOutputBytes: 2_097_152))
        #expect(context.isValid(maxOutputBytes: 2_097_152))
        #expect(context.audioState == .extracted)
        #expect(context.subtitleState == .extracted)
        let audio = try #require(context.audio)
        let wav = try #require(audio.data)
        #expect(MediaPayloadValidation.audioFormat(wav) == "wav")
        #expect(wav.count > 44 && wav.count < 20_000)
        #expect(audio.startSeconds >= 0 && audio.startSeconds < 0.001)
        #expect(audio.endSeconds > 0.99 && audio.endSeconds <= context.durationSeconds)
        let cue = try #require(context.subtitles.first)
        #expect(context.subtitles.count == 1)
        #expect(cue.text == "owned cue 一")
        #expect(abs(cue.startSeconds - 0.1) < 0.00001)
        #expect(abs(cue.endSeconds - 0.8) < 0.00001)
        let caps = ModelCapabilities(supportedModalities: .fullMultimodalInput, supportedAuth: [.apiKey])
        let message = LLMMessage(role: .user, content: "[字幕 00:00.100–00:00.800] " + cue.text,
            audios: [.init(format: "wav", base64Data: wav.base64EncodedString())])
        let first = OpenAICompatibleProvider.openAIMessageDict(message, mediaCapabilities: caps)
        let replay = OpenAICompatibleProvider.openAIMessageDict(message, mediaCapabilities: caps)
        let encode: ([String: Any]) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        #expect(try encode(first) == encode(replay))
        let parts = try #require(first["content"] as? [[String: Any]])
        let input = try #require(parts.first?["input_audio"] as? [String: String])
        #expect(input["data"] == wav.base64EncodedString())
        #expect(input["format"] == "wav")
        let responses = OpenAIResponsesProvider.responsesInputItem(message, mediaCapabilities: caps)
        #expect(responses.content.first?.inputAudio?.data == wav.base64EncodedString())
        print("VIDEO603_EXTRACTED audioBytes=\(wav.count) audioStart=\(audio.startSeconds) audioEnd=\(audio.endSeconds) cues=\(context.subtitles.count) cueStart=\(cue.startSeconds) cueEnd=\(cue.endSeconds)")
    }

    @Test func limitsAndMetadataOnlyProjectionNeverInventAnAudioPayload() async throws {
        let source = try AVFoundationVideoFrameSource(fileURL: fixture)
        let small = try #require(await source.supplementaryContext(maxOutputBytes: 44))
        #expect(small.audioState == .unavailable)
        #expect(small.audio == nil)
        #expect(small.subtitles.map(\.text) == ["owned cue 一"])
        let full = try #require(await source.supplementaryContext(maxOutputBytes: 2_097_152))
        let metadata = full.withAudioPayload(nil)
        #expect(metadata.audio?.data == nil)
        #expect(!metadata.isValid(maxOutputBytes: 2_097_152))
        #expect(metadata.isValid(maxOutputBytes: 2_097_152, requireAudioPayload: false))
        #expect(!full.isValid(maxOutputBytes: 1))
        #expect(!metadata.withAudioPayload(Data("wrong slot".utf8)).isValid(maxOutputBytes: 2_097_152))
        let invalidCue = MediaVideoSupplementaryContext(durationSeconds: 1, audioState: .absent,
            subtitleState: .extracted, audio: nil,
            subtitles: [.init(startSeconds: 0.8, endSeconds: 2, text: "outside range")])
        #expect(!invalidCue.isValid(maxOutputBytes: 100))
    }
}
