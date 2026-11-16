import Foundation

/// One turn's immutable TTS availability, with the evidence that produced it.
/// A configured SpeechTool is not itself evidence that speech can be heard.
public struct SpeechToolAvailabilitySnapshot: Equatable, Sendable {
    public enum ProbeField: String, CaseIterable, Equatable, Sendable {
        case speechLocaleResolved
        case ttsVoiceAvailable
        case audioOutputDevicePresent
        case sttRecognizerPresent
        case sttEngineAvailable
        case speechRecognitionAuthorized
        case microphoneAuthorized
        case audioInputDevicePresent
    }

    /// A source describes where an observation came from, never an inferred
    /// capability. A value with no matching source is treated as unknown.
    public enum Source: String, Equatable, Sendable {
        case unobserved
        case settingsLanguage
        case systemVoice
        case audioOutputDevice
        case recognizer
        case recognizerAvailability
        case speechRecognitionAuthorization
        case microphoneAuthorization
        case audioInputDevice
    }

    public struct ProbeSources: Equatable, Sendable {
        public let speechLocaleResolved: Source
        public let ttsVoiceAvailable: Source
        public let audioOutputDevicePresent: Source
        public let sttRecognizerPresent: Source
        public let sttEngineAvailable: Source
        public let speechRecognitionAuthorized: Source
        public let microphoneAuthorized: Source
        public let audioInputDevicePresent: Source

        public init(
            speechLocaleResolved: Source = .unobserved,
            ttsVoiceAvailable: Source = .unobserved,
            audioOutputDevicePresent: Source = .unobserved,
            sttRecognizerPresent: Source = .unobserved,
            sttEngineAvailable: Source = .unobserved,
            speechRecognitionAuthorized: Source = .unobserved,
            microphoneAuthorized: Source = .unobserved,
            audioInputDevicePresent: Source = .unobserved
        ) {
            self.speechLocaleResolved = speechLocaleResolved
            self.ttsVoiceAvailable = ttsVoiceAvailable
            self.audioOutputDevicePresent = audioOutputDevicePresent
            self.sttRecognizerPresent = sttRecognizerPresent
            self.sttEngineAvailable = sttEngineAvailable
            self.speechRecognitionAuthorized = speechRecognitionAuthorized
            self.microphoneAuthorized = microphoneAuthorized
            self.audioInputDevicePresent = audioInputDevicePresent
        }
    }

    public struct CaptureIdentity: Equatable, Sendable {
        public let turnID: String
        public let capturedAt: Date

        public init(turnID: String, capturedAt: Date) {
            self.turnID = turnID
            self.capturedAt = capturedAt
        }
    }

    /// Raw facts are retained for inspection. Nil means unmeasured, not that
    /// an output device, voice, or authorization was observed to be absent.
    public let probe: SpeechCapabilityBoundary.Probe
    public let sources: ProbeSources
    public let identity: CaptureIdentity
    /// The canonical boundary result; use `isUnknown` before presenting its
    /// reason, because the boundary intentionally fails closed for nil facts.
    public let status: SpeechCapabilityBoundary.Status
    public let unknownFields: [ProbeField]
    private let blockingFieldIsUnknown: Bool

    public init(
        probe: SpeechCapabilityBoundary.Probe,
        sources: ProbeSources,
        identity: CaptureIdentity
    ) {
        self.probe = probe
        self.sources = sources
        self.identity = identity

        // A reported Bool without the matching measured source is not proof.
        // No OS or device call occurs here; the producer supplies observations.
        let effective = SpeechCapabilityBoundary.Probe(
            speechLocaleResolved: Self.observed(probe.speechLocaleResolved, from: sources.speechLocaleResolved, expected: .settingsLanguage),
            ttsVoiceAvailable: Self.observed(probe.ttsVoiceAvailable, from: sources.ttsVoiceAvailable, expected: .systemVoice),
            audioOutputDevicePresent: Self.observed(probe.audioOutputDevicePresent, from: sources.audioOutputDevicePresent, expected: .audioOutputDevice),
            sttRecognizerPresent: Self.observed(probe.sttRecognizerPresent, from: sources.sttRecognizerPresent, expected: .recognizer),
            sttEngineAvailable: Self.observed(probe.sttEngineAvailable, from: sources.sttEngineAvailable, expected: .recognizerAvailability),
            speechRecognitionAuthorized: Self.observed(probe.speechRecognitionAuthorized, from: sources.speechRecognitionAuthorized, expected: .speechRecognitionAuthorization),
            microphoneAuthorized: Self.observed(probe.microphoneAuthorized, from: sources.microphoneAuthorized, expected: .microphoneAuthorization),
            audioInputDevicePresent: Self.observed(probe.audioInputDevicePresent, from: sources.audioInputDevicePresent, expected: .audioInputDevice)
        )
        var unknown: [ProbeField] = []
        if effective.speechLocaleResolved == nil { unknown.append(.speechLocaleResolved) }
        if effective.ttsVoiceAvailable == nil { unknown.append(.ttsVoiceAvailable) }
        if effective.audioOutputDevicePresent == nil { unknown.append(.audioOutputDevicePresent) }
        if effective.sttRecognizerPresent == nil { unknown.append(.sttRecognizerPresent) }
        if effective.sttEngineAvailable == nil { unknown.append(.sttEngineAvailable) }
        if effective.speechRecognitionAuthorized == nil { unknown.append(.speechRecognitionAuthorized) }
        if effective.microphoneAuthorized == nil { unknown.append(.microphoneAuthorized) }
        if effective.audioInputDevicePresent == nil { unknown.append(.audioInputDevicePresent) }
        unknownFields = unknown

        let boundaryStatus = SpeechCapabilityBoundary.evaluate(effective).textToSpeech
        status = boundaryStatus
        switch boundaryStatus.unsupportedReason {
        case .some(.speechLocaleUnresolved):
            blockingFieldIsUnknown = effective.speechLocaleResolved == nil
        case .some(.noVoiceForEffectiveLocale):
            blockingFieldIsUnknown = effective.ttsVoiceAvailable == nil
        case .some(.noAudioOutputDevice):
            blockingFieldIsUnknown = effective.audioOutputDevicePresent == nil
        case nil:
            blockingFieldIsUnknown = false
        default:
            // A future boundary reason not mapped here must never be shown as
            // a measured failure until its provenance rule is added.
            blockingFieldIsUnknown = true
        }
    }

    public var isSupported: Bool { status.isSupported }
    public var isUnknown: Bool { blockingFieldIsUnknown }

    /// A presentable reason only when the blocking observation was measured
    /// false. Unknown observations fail closed without claiming device loss.
    public var unsupportedReason: SpeechCapabilityBoundary.UnsupportedReason? {
        isUnknown ? nil : status.unsupportedReason
    }

    private static func observed(_ value: Bool?, from source: Source, expected: Source) -> Bool? {
        source == expected ? value : nil
    }
}
