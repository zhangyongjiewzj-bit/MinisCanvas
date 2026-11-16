import Testing
@testable import MinisCore

/// Pure-probe tests for the single authoritative speech capability
/// boundary. No device, provider or network access: every input is an
/// explicitly injected probe parameter, so all expectations are
/// deterministic and replayable.
@Suite("Speech capability boundary")
struct SpeechCapabilityBoundaryTests {

    private static let fullySupported = SpeechCapabilityBoundary.Probe(
        speechLocaleResolved: true,
        ttsVoiceAvailable: true,
        audioOutputDevicePresent: true,
        sttRecognizerPresent: true,
        sttEngineAvailable: true,
        speechRecognitionAuthorized: true,
        microphoneAuthorized: true,
        audioInputDevicePresent: true
    )

    @Test("A fully satisfied probe reports accurate supported identity for both paths")
    func supportedPathsReallyPass() {
        let snapshot = SpeechCapabilityBoundary.evaluate(Self.fullySupported)
        #expect(snapshot.textToSpeech == .supported)
        #expect(snapshot.speechRecognition == .supported)
        #expect(snapshot.status(for: .textToSpeech).isSupported)
        #expect(snapshot.status(for: .speechRecognition).unsupportedReason == nil)
    }

    @Test("An all-unknown probe (default init) fails closed — nothing is faked as available")
    func unknownProbeFailsClosed() {
        let snapshot = SpeechCapabilityBoundary.evaluate(SpeechCapabilityBoundary.Probe())
        #expect(snapshot.textToSpeech == .unsupported(.speechLocaleUnresolved))
        #expect(snapshot.speechRecognition == .unsupported(.speechLocaleUnresolved))
        #expect(!snapshot.textToSpeech.isSupported)
        #expect(!snapshot.speechRecognition.isSupported)
    }

    @Test("TTS unsupported entries carry the exact first unmet precondition")
    func textToSpeechFailClosedReasons() {
        // Locale unresolved blocks everything else.
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(speechLocaleResolved: false)
        ).textToSpeech == .unsupported(.speechLocaleUnresolved))
        // No voice for the effective locale.
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(ttsVoiceAvailable: false)
        ).textToSpeech == .unsupported(.noVoiceForEffectiveLocale))
        // Voice exists but nothing is audible.
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(audioOutputDevicePresent: false)
        ).textToSpeech == .unsupported(.noAudioOutputDevice))
        // Measured-false and un-measured-nil both fail closed.
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(ttsVoiceAvailable: nil)
        ).textToSpeech == .unsupported(.noVoiceForEffectiveLocale))
    }

    @Test("STT unsupported entries are presented explicitly, in fixed precedence")
    func speechRecognitionFailClosedReasons() {
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(speechRecognitionAuthorized: false)
        ).speechRecognition == .unsupported(.speechRecognitionNotAuthorized))
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(microphoneAuthorized: false)
        ).speechRecognition == .unsupported(.microphoneNotAuthorized))
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(sttRecognizerPresent: false)
        ).speechRecognition == .unsupported(.recognizerMissingForEffectiveLocale))
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(sttEngineAvailable: false)
        ).speechRecognition == .unsupported(.recognizerEngineUnavailable))
        #expect(SpeechCapabilityBoundary.evaluate(
            Self.probe(audioInputDevicePresent: false)
        ).speechRecognition == .unsupported(.noAudioInputDevice))
    }

    @Test("One flipped precondition never leaves the path pretending to work")
    func supportedRequiresEveryPrecondition() {
        for flipped in Self.singleSignalRemovals() {
            let snapshot = SpeechCapabilityBoundary.evaluate(flipped)
            #expect(!snapshot.textToSpeech.isSupported || !snapshot.speechRecognition.isSupported)
            // A genuinely unsupported path must always name a reason.
            if case .unsupported(let reason) = snapshot.textToSpeech {
                #expect(reason.rawValue.isEmpty == false)
            }
            if case .unsupported(let reason) = snapshot.speechRecognition {
                #expect(reason.rawValue.isEmpty == false)
            }
        }
    }

    @Test("Same input replays to an identical snapshot")
    func deterministicReplay() {
        let probes: [SpeechCapabilityBoundary.Probe] = [
            Self.fullySupported,
            SpeechCapabilityBoundary.Probe(),
            Self.probe(sttEngineAvailable: false),
            Self.probe(ttsVoiceAvailable: false, microphoneAuthorized: false),
        ]
        for probe in probes {
            #expect(SpeechCapabilityBoundary.evaluate(probe) == SpeechCapabilityBoundary.evaluate(probe))
        }
    }

    // MARK: - Helpers (pure, no device access)

    private static func probe(
        speechLocaleResolved: Bool? = true,
        ttsVoiceAvailable: Bool? = true,
        audioOutputDevicePresent: Bool? = true,
        sttRecognizerPresent: Bool? = true,
        sttEngineAvailable: Bool? = true,
        speechRecognitionAuthorized: Bool? = true,
        microphoneAuthorized: Bool? = true,
        audioInputDevicePresent: Bool? = true
    ) -> SpeechCapabilityBoundary.Probe {
        SpeechCapabilityBoundary.Probe(
            speechLocaleResolved: speechLocaleResolved,
            ttsVoiceAvailable: ttsVoiceAvailable,
            audioOutputDevicePresent: audioOutputDevicePresent,
            sttRecognizerPresent: sttRecognizerPresent,
            sttEngineAvailable: sttEngineAvailable,
            speechRecognitionAuthorized: speechRecognitionAuthorized,
            microphoneAuthorized: microphoneAuthorized,
            audioInputDevicePresent: audioInputDevicePresent
        )
    }

    /// Each variant removes exactly one supporting signal from the
    /// fully-supported probe.
    private static func singleSignalRemovals() -> [SpeechCapabilityBoundary.Probe] {
        [
            probe(speechLocaleResolved: nil),
            probe(ttsVoiceAvailable: nil),
            probe(audioOutputDevicePresent: nil),
            probe(sttRecognizerPresent: nil),
            probe(sttEngineAvailable: nil),
            probe(speechRecognitionAuthorized: nil),
            probe(microphoneAuthorized: nil),
            probe(audioInputDevicePresent: nil),
        ]
    }
}
