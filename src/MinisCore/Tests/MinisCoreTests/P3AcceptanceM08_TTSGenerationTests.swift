import AVFoundation
import Testing
@testable import MinisCore

/// Only synthetic utterances and callbacks are used; no voice, output device,
/// permission, or audio session is queried by this backend.
@MainActor
private final class InterleavedSpeechBackend: SpeechSynthesisPlaybackBackend {
    var isSpeaking = false
    var startsImmediately = true
    var onFinish: ((AVSpeechUtterance) -> Void)?
    var onCancel: ((AVSpeechUtterance) -> Void)?
    private(set) var currentUtterance: AVSpeechUtterance?
    private(set) var stopCount = 0

    func stop() {
        stopCount += 1
        isSpeaking = false
        currentUtterance = nil
    }

    func prepareUtterance(text: String, voice: String?, defaultLanguageCode: String) -> AVSpeechUtterance {
        AVSpeechUtterance(string: text)
    }

    func speak(_ utterance: AVSpeechUtterance) {
        currentUtterance = utterance
        isSpeaking = startsImmediately
    }

    func finish(_ utterance: AVSpeechUtterance) {
        if let currentUtterance, currentUtterance === utterance {
            self.currentUtterance = nil
            isSpeaking = false
        }
        onFinish?(utterance)
    }

    func cancel(_ utterance: AVSpeechUtterance) {
        if let currentUtterance, currentUtterance === utterance {
            self.currentUtterance = nil
            isSpeaking = false
        }
        onCancel?(utterance)
    }
}

@Suite("M08 speech completion generation")
@MainActor
struct P3AcceptanceM08_TTSGenerationTests {
    @Test("late completion and cancellation of stopped utterance cannot finish the next speak")
    func staleCallbacksCannotFinishCurrentPlayback() async throws {
        let backend = InterleavedSpeechBackend()
        let synthesizer = SpeechSynthesizer(backend: backend)
        let tool = SpeechTool(synthesizer: synthesizer)

        let first = try await tool.execute(name: "speech", input: [
            "action": "speak", "text": "第一轮",
        ])
        #expect(first.contains("已开始朗读"))
        let firstGeneration = try #require(synthesizer.activeGeneration)
        let stoppedUtterance = try #require(backend.currentUtterance)

        let stopped = try await tool.execute(name: "speech", input: ["action": "stop"])
        #expect(stopped == "已停止朗读。")
        #expect(synthesizer.activeGeneration == nil)
        #expect(backend.stopCount == 1)

        let second = try await tool.execute(name: "speech", input: [
            "action": "speak", "text": "第二轮",
        ])
        #expect(second.contains("已开始朗读"))
        let secondGeneration = try #require(synthesizer.activeGeneration)
        #expect(secondGeneration != firstGeneration)
        let currentUtterance = try #require(backend.currentUtterance)
        #expect(synthesizer.isSpeaking)

        backend.finish(stoppedUtterance)
        #expect(synthesizer.activeGeneration == secondGeneration)
        #expect(synthesizer.isSpeaking)
        backend.cancel(stoppedUtterance)
        #expect(synthesizer.activeGeneration == secondGeneration)
        #expect(synthesizer.isSpeaking)
        #expect(backend.stopCount == 1)

        backend.finish(currentUtterance)
        #expect(synthesizer.activeGeneration == nil)
        #expect(synthesizer.isSpeaking == false)
    }

    @Test("stop invalidates an accepted utterance before the backend reports speaking")
    func pendingStopInvalidatesPlayback() async throws {
        let backend = InterleavedSpeechBackend()
        backend.startsImmediately = false
        let synthesizer = SpeechSynthesizer(backend: backend)
        let tool = SpeechTool(synthesizer: synthesizer)

        let start = try await tool.execute(name: "speech", input: [
            "action": "speak", "text": "待播报",
        ])
        #expect(start.contains("已开始朗读"))
        let pendingUtterance = try #require(backend.currentUtterance)
        #expect(backend.isSpeaking == false)
        #expect(synthesizer.isSpeaking)

        let stopped = try await tool.execute(name: "speech", input: ["action": "stop"])
        #expect(stopped == "已停止朗读。")
        #expect(backend.stopCount == 1)
        #expect(backend.currentUtterance == nil)
        #expect(synthesizer.activeGeneration == nil)

        backend.finish(pendingUtterance)
        #expect(synthesizer.activeGeneration == nil)
        #expect(synthesizer.isSpeaking == false)
    }

    @Test("cancellation of the current utterance clears that playback")
    func currentCancellationClearsPlayback() async throws {
        let backend = InterleavedSpeechBackend()
        let synthesizer = SpeechSynthesizer(backend: backend)
        let tool = SpeechTool(synthesizer: synthesizer)

        let start = try await tool.execute(name: "speech", input: [
            "action": "speak", "text": "当前轮",
        ])
        #expect(start.contains("已开始朗读"))
        let currentUtterance = try #require(backend.currentUtterance)
        #expect(synthesizer.activeGeneration != nil)

        backend.cancel(currentUtterance)
        #expect(synthesizer.activeGeneration == nil)
        #expect(synthesizer.isSpeaking == false)
        #expect(backend.stopCount == 0)
    }
}
