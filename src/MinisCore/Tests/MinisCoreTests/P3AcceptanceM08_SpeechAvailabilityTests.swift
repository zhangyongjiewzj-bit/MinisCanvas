import Foundation
import Testing
@testable import MinisCore

/// Synthetic capability facts only. No device or system permission is used.
@Suite("M08 per-turn speech tool availability")
struct P3AcceptanceM08_SpeechAvailabilityTests {
    private let identity = SpeechToolAvailabilitySnapshot.CaptureIdentity(
        turnID: "synthetic-turn", capturedAt: Date(timeIntervalSince1970: 1)
    )

    @Test("evidenced TTS remains available despite unrelated STT denial")
    func supportedTTSDoesNotDependOnSTTPermission() {
        let raw = SpeechCapabilityBoundary.Probe(
            speechLocaleResolved: true,
            ttsVoiceAvailable: true,
            audioOutputDevicePresent: true,
            speechRecognitionAuthorized: false,
            microphoneAuthorized: false
        )
        let snapshot = SpeechToolAvailabilitySnapshot(
            probe: raw,
            sources: .init(
                speechLocaleResolved: .settingsLanguage,
                ttsVoiceAvailable: .systemVoice,
                audioOutputDevicePresent: .audioOutputDevice,
                speechRecognitionAuthorized: .speechRecognitionAuthorization,
                microphoneAuthorized: .microphoneAuthorization
            ),
            identity: identity
        )

        #expect(snapshot.probe == raw)
        #expect(snapshot.identity.turnID == "synthetic-turn")
        #expect(snapshot.status == .supported)
        #expect(snapshot.isSupported)
        #expect(snapshot.isUnknown == false)
        #expect(snapshot.unsupportedReason == nil)
        #expect(snapshot.unknownFields.contains(.sttRecognizerPresent))
    }

    @Test("unknown output fails closed without claiming the device is missing")
    func unknownOutputIsNotMeasuredAbsence() {
        let raw = SpeechCapabilityBoundary.Probe(
            speechLocaleResolved: true,
            ttsVoiceAvailable: true,
            audioOutputDevicePresent: nil
        )
        let sources = SpeechToolAvailabilitySnapshot.ProbeSources(
            speechLocaleResolved: .settingsLanguage,
            ttsVoiceAvailable: .systemVoice
        )
        let snapshot = SpeechToolAvailabilitySnapshot(
            probe: raw, sources: sources, identity: identity
        )

        #expect(snapshot.probe == raw)
        #expect(snapshot.sources == sources)
        #expect(snapshot.isSupported == false)
        #expect(snapshot.isUnknown)
        #expect(snapshot.unknownFields.contains(.audioOutputDevicePresent))
        #expect(snapshot.unsupportedReason == nil)
        // The boundary's internal reason remains visible for diagnostics,
        // but is not a claim that a device was actually observed missing.
        #expect(snapshot.status == .unsupported(.noAudioOutputDevice))
    }

    @Test("measured absence retains reason; an unsourced true cannot enable TTS")
    func observedAbsenceAndUnsourcedTrueStayDistinct() {
        let raw = SpeechCapabilityBoundary.Probe(
            speechLocaleResolved: true,
            ttsVoiceAvailable: true,
            audioOutputDevicePresent: false
        )
        let observed = SpeechToolAvailabilitySnapshot(
            probe: raw,
            sources: .init(
                speechLocaleResolved: .settingsLanguage,
                ttsVoiceAvailable: .systemVoice,
                audioOutputDevicePresent: .audioOutputDevice
            ),
            identity: identity
        )
        #expect(observed.isSupported == false)
        #expect(observed.isUnknown == false)
        #expect(observed.unsupportedReason == .noAudioOutputDevice)

        let unsourcedTrue = SpeechToolAvailabilitySnapshot(
            probe: .init(
                speechLocaleResolved: true,
                ttsVoiceAvailable: true,
                audioOutputDevicePresent: true
            ),
            sources: .init(
                speechLocaleResolved: .settingsLanguage,
                ttsVoiceAvailable: .systemVoice
            ),
            identity: identity
        )
        #expect(unsourcedTrue.isSupported == false)
        #expect(unsourcedTrue.isUnknown)
        #expect(unsourcedTrue.unsupportedReason == nil)
    }
}
