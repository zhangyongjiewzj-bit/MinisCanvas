import AVFoundation
import Foundation
import Speech
import Testing
@testable import MinisCore

@Suite("Speech runtime callback queues")
@MainActor
struct SpeechRuntimeCallbackQueueTests {
    @Test
    func recognitionCallbackCanEnterFromWorkerQueue() async {
        let owner = SpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        let callback = SpeechRecognizer.makeRecognitionCallback(owner: owner, generation: 1)

        let calledOffMain = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                callback(nil, nil)
                continuation.resume(returning: !Thread.isMainThread)
            }
        }

        #expect(calledOffMain)
        #expect(owner.state == .idle)
        #expect(owner.recognizedText.isEmpty)
    }

    @Test(arguments: [true, false])
    func audioTapCallbackAppendsSynchronouslyOnWorkerQueue(retainRequest: Bool) async {
        let calledOffMain = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Keep all non-Sendable AVFoundation values on this worker.
                var request: SFSpeechAudioBufferRecognitionRequest? = SFSpeechAudioBufferRecognitionRequest()
                let callback = SpeechRecognizer.makeAudioTapCallback(request: request!)
                let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
                buffer.frameLength = 4
                if !retainRequest { request = nil }
                callback(buffer, AVAudioTime(hostTime: 0))
                withExtendedLifetime(request) {}
                continuation.resume(returning: !Thread.isMainThread)
            }
        }

        #expect(calledOffMain)
    }
}
