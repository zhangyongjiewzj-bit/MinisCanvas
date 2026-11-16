import AVFoundation
import Foundation
import Testing
@testable import MinisCore

/// Carries framework-owned objects across the synthetic callback queue just
/// as AVSpeechSynthesizer does. The test never asks either synthesizer to speak.
private final class SpeechDelegateCallbackInput2512: @unchecked Sendable {
    let backend: AVSpeechPlaybackBackend
    let sender: AVSpeechSynthesizer
    let finished: AVSpeechUtterance
    let cancelled: AVSpeechUtterance

    init(backend: AVSpeechPlaybackBackend, sender: AVSpeechSynthesizer,
         finished: AVSpeechUtterance, cancelled: AVSpeechUtterance) {
        self.backend = backend
        self.sender = sender
        self.finished = finished
        self.cancelled = cancelled
    }
}

@Suite("TTS production delegate callback queue")
@MainActor
struct SpeechTTSDelegateCallback2512Tests {
    @Test("external finish and cancel callbacks keep exact utterance and distinct terminal channels")
    func callbacksFromWorkerQueueReachMainActorWithExactIdentity() async throws {
        let backend = AVSpeechPlaybackBackend()
        let finished = AVSpeechUtterance(string: "合成完成回调")
        let cancelled = AVSpeechUtterance(string: "合成取消回调")
        let input = SpeechDelegateCallbackInput2512(
            backend: backend, sender: AVSpeechSynthesizer(),
            finished: finished, cancelled: cancelled
        )
        var finishedCallbacks: [(AVSpeechUtterance, Bool)] = []
        var cancelledCallbacks: [(AVSpeechUtterance, Bool)] = []
        backend.onFinish = { utterance in
            finishedCallbacks.append((utterance, Thread.isMainThread))
        }
        backend.onCancel = { utterance in
            cancelledCallbacks.append((utterance, Thread.isMainThread))
        }

        let invokedOffMain = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                input.backend.speechSynthesizer(input.sender, didFinish: input.finished)
                input.backend.speechSynthesizer(input.sender, didCancel: input.cancelled)
                continuation.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(invokedOffMain)

        for _ in 0..<200 where finishedCallbacks.count + cancelledCallbacks.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(finishedCallbacks.count == 1)
        #expect(cancelledCallbacks.count == 1)
        #expect(finishedCallbacks.first?.0 === finished)
        #expect(cancelledCallbacks.first?.0 === cancelled)
        #expect(finishedCallbacks.first?.1 == true)
        #expect(cancelledCallbacks.first?.1 == true)
    }
}
