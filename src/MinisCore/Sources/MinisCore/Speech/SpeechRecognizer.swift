import AVFoundation
import Foundation
import Speech

// MARK: - Errors

/// Errors surfaced by `SpeechRecognizer`.
public enum SpeechRecognizerError: Error, Equatable, LocalizedError {
    /// Speech-recognition or microphone permission was not granted.
    case notAuthorized
    /// At least one required permission has not been decided by the user.
    case authorizationUndetermined
    /// A future platform authorization status cannot be classified safely.
    case authorizationStatusUnknown
    /// `SFSpeechRecognizer` is unavailable for the requested locale
    /// (nil recognizer or `isAvailable == false`).
    case recognizerUnavailable(String)
    /// The audio engine / tap could not start (no mic, bad format, …).
    case audioEngineFailed(String)
    /// `stop()` was called while not recording (no-op — returns current text).
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition requires permission (NSSpeechRecognitionUsageDescription + NSMicrophoneUsageDescription)"
        case .authorizationUndetermined:
            return "Speech recognition and microphone permissions must be decided before recording"
        case .authorizationStatusUnknown:
            return "Speech recognition or microphone authorization status is unknown"
        case .recognizerUnavailable(let locale):
            return "Speech recognizer unavailable for locale: \(locale)"
        case .audioEngineFailed(let detail):
            return "Audio engine failed: \(detail)"
        case .notRecording:
            return "Recognizer is not recording"
        }
    }
}

// MARK: - Recognizer

/// macOS speech recognition around `SFSpeechRecognizer` + `AVAudioEngine`:
/// `start()` begins capturing the microphone, partial results stream into
/// `recognizedText`, `stop()` finalizes and returns the best transcription.
///
/// - Important (GUI + permissions): recognition is **not usable in the
///   headless test / CI environment**. It requires:
///   1. A GUI session with a working microphone input device.
///   2. User-granted permissions — declare both Info.plist keys in the
///      host app:
///        - `NSSpeechRecognitionUsageDescription` (speech recognition)
///        - `NSMicrophoneUsageDescription` (microphone capture)
///   3. Network access for server-side recognition (or a locale that
///      supports on-device recognition).
///   In headless CLI runs the class constructs safely but `start()` throws
///   `notAuthorized` / `audioEngineFailed` — treat it as GUI-only and keep
///   it out of unit tests.
@MainActor
public final class SpeechRecognizer {

    public enum State: Equatable {
        case idle
        case recording
    }

    public private(set) var state: State = .idle
    /// Latest partial / final transcription (updated by the result handler).
    public var recognizedText: String { resultBuffer.text }

    private let locale: Locale
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var resultBuffer = SpeechRecognitionResultBuffer()
    private let audioEngine = AVAudioEngine()
    private let logger = AppLogger(category: "Speech")

    public init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Production initializer driven by the existing
    /// `AppSettings.general.language` value. Invalid or missing values fail
    /// closed instead of silently falling back to a different locale.
    public convenience init(generalLanguage: String?) throws {
        try self.init(locale: SpeechLocaleResolver.runtimeLocale(for: generalLanguage))
    }

    /// Current speech-recognition authorization status (no prompt).
    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// A pure mapping for the two permissions required before opening the
    /// microphone. Neither status lookup nor this mapping requests access.
    static func startAuthorizationError(
        speech: SFSpeechRecognizerAuthorizationStatus,
        microphone: AVAuthorizationStatus
    ) -> SpeechRecognizerError? {
        switch speech {
        case .authorized: break
        case .denied, .restricted: return .notAuthorized
        case .notDetermined: return .authorizationUndetermined
        @unknown default: return .authorizationStatusUnknown
        }

        switch microphone {
        case .authorized: return nil
        case .denied, .restricted: return .notAuthorized
        case .notDetermined: return .authorizationUndetermined
        @unknown default: return .authorizationStatusUnknown
        }
    }

    /// Whether the recognizer exists and is currently available
    /// (network reachable / on-device model present).
    ///
    /// Fail-closed capability boundary (P3-SPEECH-01): a `nil` recognizer —
    /// the missing-device / missing-locale case modelled by
    /// `SpeechCapabilityBoundary` as `.recognizerMissingForEffectiveLocale` —
    /// reports `false`. Missing evidence is never upgraded to availability, and
    /// there is no silent fallback that would let `start()` pretend the
    /// capability exists.
    public var isAvailable: Bool {
        speechRecognizer?.isAvailable ?? false
    }

    /// Prompt the user for speech-recognition + microphone access.
    /// Returns `true` only when **both** are granted.
    /// (macOS uses `AVCaptureDevice.requestAccess(for: .audio)` for the mic;
    /// there is no `AVAudioSession` on macOS.)
    public func requestAuthorization() async -> Bool {
        let speechGranted = await Self.requestSpeechAuthorization()
        guard speechGranted else {
            logger.warning("Speech recognition not authorized")
            return false
        }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            logger.warning("Microphone permission not granted")
            return false
        }
        logger.info("Speech + mic permissions granted")
        return true
    }

    /// Speech may call its legacy completion on a TCC worker queue. Form the
    /// callback outside this MainActor type's isolation so Swift does not
    /// attach a main-executor assertion to the callback before it resumes us.
    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await awaitAuthorizationCallback { complete in
            SFSpeechRecognizer.requestAuthorization { status in
                complete(status == .authorized)
            }
        }
    }

    /// Injectable callback bridge for a worker-queue regression without
    /// requesting system permission or opening microphone hardware.
    nonisolated static func awaitAuthorizationCallback(
        _ register: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            register { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Begin capturing the microphone and streaming recognition results.
    /// Throws when permissions are missing, the recognizer is unavailable,
    /// or the audio engine cannot start. No-op when already recording.
    public func start() throws {
        guard state == .idle else { return }
        if let authorizationError = Self.startAuthorizationError(
            speech: SFSpeechRecognizer.authorizationStatus(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio)
        ) {
            throw authorizationError
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw SpeechRecognizerError.recognizerUnavailable(locale.identifier)
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        // Defensive: remove any stale tap before installing a new one.
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.channelCount > 0 else {
            recognitionRequest = nil
            throw SpeechRecognizerError.audioEngineFailed("Recording format has 0 channels")
        }

        do {
            inputNode.installTap(
                onBus: 0, bufferSize: 1024, format: recordingFormat,
                block: Self.makeAudioTapCallback(request: request)
            )
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            // Roll back anything that partially succeeded so the next attempt
            // starts clean and no orphaned tap remains on the input node.
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            throw SpeechRecognizerError.audioEngineFailed(error.localizedDescription)
        }

        let generation = resultBuffer.begin()
        recognitionTask = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeRecognitionCallback(owner: self, generation: generation)
        )

        state = .recording
        logger.info("Recording started (\(locale.identifier))")
    }

    /// AVAudioEngine invokes its tap on an audio worker. Build the block in a
    /// nonisolated context; appending buffers is the only work it performs.
    nonisolated static func makeAudioTapCallback(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> AVAudioNodeTapBlock {
        { [weak request] buffer, _ in
            request?.append(buffer)
        }
    }

    /// Speech result callbacks can also arrive on background queues. Reduce
    /// framework values to Sendable primitives before hopping to MainActor;
    /// the generation fence still rejects results from a cancelled recording.
    nonisolated static func makeRecognitionCallback(
        owner: SpeechRecognizer,
        generation: UInt64
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                if owner.resultBuffer.receive(
                    generation: generation,
                    text: text,
                    isFinal: isFinal,
                    failed: failed
                ) {
                    owner.tearDown()
                }
            }
        }
    }

    /// Finalize the current recording and return the best transcription so far.
    /// No-op (returns `recognizedText`) when not recording.
    @discardableResult
    public func stop() -> String {
        guard state == .recording else { return recognizedText }
        tearDown()
        logger.info("Recording stopped")
        return recognizedText
    }

    private func tearDown() {
        resultBuffer.stop()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        state = .idle
    }
}
