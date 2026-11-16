import Foundation

// MARK: - Speech Capability Boundary (P3-SPEECH-01)

/// Single authoritative source for audio/TTS/STT capability identity.
///
/// Every availability decision that previously lived scattered across
/// `SpeechRecognizer.isAvailable`, `SpeechSynthesizer.speak` result
/// strings, `SpeechTool` prompts and `BridgeStore`'s `try?` runtime
/// composition converges here into ONE pure function. The function takes
/// explicit device/engine probe parameters (never touches
/// `AVSpeechSynthesizer`, `SFSpeechRecognizer`, `AVAudioEngine` or the
/// network) and returns an accurate capability identity plus, for every
/// unsupported path, an explicit machine-readable reason.
///
/// Contract (Canonical 总表:331 — 能力标识准确、支持路径真实通过、不支持
/// 入口明确呈现，不得把不支持的能力伪装成可用):
/// 1. **Accurate identity** — a capability is reported `.supported` only
///    when every precondition observable through the probe is satisfied.
/// 2. **Fail-closed** — any probe signal left `nil` (unknown / not
///    measured) makes the affected capability `.unsupported`. Missing
///    evidence is never upgraded to availability.
/// 3. **Explicit presentation** — unsupported results carry a concrete
///    `SpeechCapabilityUnsupportedReason`; consumers must present it as-is
///    instead of faking availability or silently disabling entries.
/// 4. **Deterministic replay** — the function is pure: the same probe
///    always produces an identical snapshot (`Equatable`), so decisions
///    can be logged and replayed in tests without a device or provider.
public enum SpeechCapabilityBoundary {

    /// The canonical set of audio capabilities this boundary owns.
    public enum Capability: String, CaseIterable, Equatable, Sendable {
        /// Text-to-speech output (macOS synthesis path).
        case textToSpeech
        /// Speech-to-text recognition (recognizer + microphone path).
        case speechRecognition
    }

    /// Explicit reason a capability is NOT available. Each case maps to a
    /// distinct, presentable condition — consumers must not collapse them
    /// into a generic "unavailable" and must not offer the entry as if it
    /// worked.
    public enum UnsupportedReason: String, Equatable, Sendable {
        // -- shared --
        /// The app-language → locale mapping for speech failed (the
        /// effective speech locale is missing/unsupported), so neither the
        /// synthesizer voice nor the recognizer can be bound reliably.
        case speechLocaleUnresolved
        // -- textToSpeech --
        /// No system voice could be resolved for the effective speech
        /// locale, so TTS would silently fall back to a wrong-language
        /// voice or stay mute.
        case noVoiceForEffectiveLocale
        /// No audio output device is present; TTS "success" would be a
        /// fake (nothing audible).
        case noAudioOutputDevice
        // -- speechRecognition --
        /// `SFSpeechRecognizer` authorization was denied or has not been
        /// granted.
        case speechRecognitionNotAuthorized
        /// Microphone access was denied or has not been granted.
        case microphoneNotAuthorized
        /// No recognizer exists for the effective speech locale.
        case recognizerMissingForEffectiveLocale
        /// The recognizer exists but its engine reports itself unavailable
        /// (server unreachable without on-device support, model missing).
        case recognizerEngineUnavailable
        /// No audio input device is present; recording could never capture.
        case noAudioInputDevice
    }

    /// Accurate identity for one capability.
    public enum Status: Equatable, Sendable {
        case supported
        case unsupported(UnsupportedReason)

        public var isSupported: Bool {
            if case .supported = self { return true }
            return false
        }

        /// The explicit reason when unsupported, `nil` only when the
        /// capability genuinely passes.
        public var unsupportedReason: UnsupportedReason? {
            switch self {
            case .supported: return nil
            case .unsupported(let reason): return reason
            }
        }
    }

    /// Explicit probe parameters. Every field is optional so "not
    /// measured" is representable and fails closed; nothing here may be
    /// filled by touching a real device inside this module.
    public struct Probe: Equatable, Sendable {
        /// Whether `SpeechLocaleResolver` produced an effective runtime
        /// speech locale (`true` = resolved, `false` = resolved-and-failed
        /// is not representable — a failed mapping is `false`, an
        /// un-measured mapping is `nil`).
        public let speechLocaleResolved: Bool?
        /// Whether a voice exists for the effective locale.
        public let ttsVoiceAvailable: Bool?
        /// Whether an audio output device is present.
        public let audioOutputDevicePresent: Bool?
        /// Whether a recognizer object exists for the effective locale.
        public let sttRecognizerPresent: Bool?
        /// Whether the recognizer engine currently reports availability
        /// (on-device support OR reachable server, per the platform).
        public let sttEngineAvailable: Bool?
        /// Whether speech-recognition authorization is granted.
        public let speechRecognitionAuthorized: Bool?
        /// Whether microphone authorization is granted.
        public let microphoneAuthorized: Bool?
        /// Whether an audio input device (microphone) is present.
        public let audioInputDevicePresent: Bool?

        public init(
            speechLocaleResolved: Bool? = nil,
            ttsVoiceAvailable: Bool? = nil,
            audioOutputDevicePresent: Bool? = nil,
            sttRecognizerPresent: Bool? = nil,
            sttEngineAvailable: Bool? = nil,
            speechRecognitionAuthorized: Bool? = nil,
            microphoneAuthorized: Bool? = nil,
            audioInputDevicePresent: Bool? = nil
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

    /// Deterministic snapshot of all owned capabilities for one probe.
    public struct Snapshot: Equatable, Sendable {
        public let textToSpeech: Status
        public let speechRecognition: Status

        public func status(for capability: Capability) -> Status {
            switch capability {
            case .textToSpeech: return textToSpeech
            case .speechRecognition: return speechRecognition
            }
        }
    }

    /// The single pure decision function. Order of checks per capability
    /// is fixed (locale → engine/voice → permission → device) so replay
    /// is stable and the first unmet precondition is the reported reason.
    public static func evaluate(_ probe: Probe) -> Snapshot {
        Snapshot(
            textToSpeech: evaluateTextToSpeech(probe),
            speechRecognition: evaluateSpeechRecognition(probe)
        )
    }

    // MARK: - Per-capability evaluation (fixed precedence)

    private static func evaluateTextToSpeech(_ probe: Probe) -> Status {
        guard probe.speechLocaleResolved == true else { return .unsupported(.speechLocaleUnresolved) }
        guard probe.ttsVoiceAvailable == true else { return .unsupported(.noVoiceForEffectiveLocale) }
        guard probe.audioOutputDevicePresent == true else { return .unsupported(.noAudioOutputDevice) }
        return .supported
    }

    private static func evaluateSpeechRecognition(_ probe: Probe) -> Status {
        guard probe.speechLocaleResolved == true else { return .unsupported(.speechLocaleUnresolved) }
        guard probe.speechRecognitionAuthorized == true else { return .unsupported(.speechRecognitionNotAuthorized) }
        guard probe.microphoneAuthorized == true else { return .unsupported(.microphoneNotAuthorized) }
        guard probe.sttRecognizerPresent == true else { return .unsupported(.recognizerMissingForEffectiveLocale) }
        guard probe.sttEngineAvailable == true else { return .unsupported(.recognizerEngineUnavailable) }
        guard probe.audioInputDevicePresent == true else { return .unsupported(.noAudioInputDevice) }
        return .supported
    }
}
