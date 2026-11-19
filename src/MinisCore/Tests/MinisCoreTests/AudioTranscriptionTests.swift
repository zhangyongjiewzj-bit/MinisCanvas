import Foundation
import Testing
@testable import MinisCore

@Suite("音频附件本机转写：计划与格式")
struct AudioTranscriptionTests {
    @Test("超过 55 秒的音频等长切段，每段不超过上限且首尾相接")
    func longAudioIsSplitIntoEqualSegments() {
        let segments = AudioTranscriptionPlan.segments(totalDuration: 130)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.durationSeconds <= AudioTranscriptionPlan.maxSegmentSeconds })
        #expect(segments.map(\.index) == [0, 1, 2])
        #expect(segments[0].startSeconds == 0)
        let last = segments[2]
        #expect(abs((last.startSeconds + last.durationSeconds) - 130) < 0.0001)
        #expect(AudioTranscriptionPlan.segments(totalDuration: 40).count == 1)
        #expect(AudioTranscriptionPlan.segments(totalDuration: 0).isEmpty)
    }

    @Test("各段文字按语言拼接，头部写文件名与 mm:ss 时长")
    func transcriptIsJoinedAndHeadered() {
        #expect(AudioTranscriptFormat.joinSegments(["你好，", " 世界 ", "", "hello", "world"]) == "你好，世界hello world")
        let text = AudioTranscriptFormat.modelText(fileName: "会议.m4a", durationSeconds: 125.4, body: "  内容  ")
        #expect(text == "[音频转写：会议.m4a，时长 02:05]\n内容")
    }

    @Test("模型是否支持音频决定转写：能收就原样发，不能收且无文字就先转写")
    func transcriptionDecision() {
        #expect(AudioTranscriptionDecision.action(modelAcceptsAudio: true, transcriptText: nil) == .sendAudioNatively)
        #expect(AudioTranscriptionDecision.action(modelAcceptsAudio: false, transcriptText: "  ") == .needsTranscription)
        #expect(AudioTranscriptionDecision.action(modelAcceptsAudio: false, transcriptText: "文字") == .sendTranscript)
        #expect(AudioTranscriptionDecision.route(recognizerAvailable: true, onDeviceSupported: false) == .requiresOnlineConsent)
        #expect(AudioTranscriptionDecision.route(recognizerAvailable: true, onDeviceSupported: true) == .onDevice)
    }
}
