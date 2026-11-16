import AVFoundation
import Speech
import Testing
@testable import MinisCore

/// Result callbacks are synthetic strings; no microphone or authorization
/// service is consulted by this suite.
@Suite("M08 speech recognition result ownership")
@MainActor
struct P3AcceptanceM08_RecognizerLifecycleTests {
    @Test("start authorization classifies microphone refusal before audio capture")
    func microphoneRefusalIsAuthorizationError() {
        #expect(SpeechRecognizer.startAuthorizationError(
            speech: .authorized, microphone: .denied
        ) == .notAuthorized)
        #expect(SpeechRecognizer.startAuthorizationError(
            speech: .authorized, microphone: .restricted
        ) == .notAuthorized)
        #expect(SpeechRecognizer.startAuthorizationError(
            speech: .authorized, microphone: .notDetermined
        ) == .authorizationUndetermined)
        #expect(SpeechRecognizer.startAuthorizationError(
            speech: .authorized, microphone: .authorized
        ) == nil)
    }

    @Test("speech refusal and undecided status fail before microphone capture")
    func speechAuthorizationPrecedesMicrophone() {
        #expect(SpeechRecognizer.startAuthorizationError(
            speech: .denied, microphone: .authorized
        ) == .notAuthorized)
        #expect(SpeechRecognizer.startAuthorizationError(
            speech: .notDetermined, microphone: .denied
        ) == .authorizationUndetermined)
    }

    @Test("late final text from a stopped recording cannot enter its successor")
    func stoppedGenerationCannotWriteIntoNextRecording() {
        var results = SpeechRecognitionResultBuffer()
        let first = results.begin()
        #expect(results.receive(
            generation: first, text: "第一段", isFinal: false, failed: false
        ) == false)
        #expect(results.stop() == "第一段")

        let second = results.begin()
        #expect(results.text.isEmpty)
        #expect(results.receive(
            generation: first, text: "迟到的旧结果", isFinal: true, failed: false
        ) == false)
        #expect(results.text.isEmpty)
        let acceptedNewFinal = results.receive(
            generation: second, text: "新结果", isFinal: true, failed: false
        )
        #expect(acceptedNewFinal)
        #expect(results.text == "新结果")
        #expect(results.receive(
            generation: second, text: "终态后迟到", isFinal: true, failed: false
        ) == false)
        #expect(results.text == "新结果")
    }

    @Test("a failed recording closes its generation without replacing prior text")
    func recognitionErrorInvalidatesResultGeneration() {
        var results = SpeechRecognitionResultBuffer()
        let generation = results.begin()
        #expect(results.receive(
            generation: generation, text: "部分文本", isFinal: false, failed: false
        ) == false)
        let terminatedOnError = results.receive(
            generation: generation, text: nil, isFinal: false, failed: true
        )
        #expect(terminatedOnError)
        #expect(results.text == "部分文本")
        #expect(results.receive(
            generation: generation, text: "错误后迟到", isFinal: true, failed: false
        ) == false)
        #expect(results.text == "部分文本")
    }
}
