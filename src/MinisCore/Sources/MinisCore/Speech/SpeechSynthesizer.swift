import AVFoundation
import Foundation

/// The speech tool's main-actor output seam. A synthetic driver can verify
/// action routing without opening an audio device or speaking in tests.
@MainActor
public protocol SpeechSynthesisDriving: AnyObject, Sendable {
    var isSpeaking: Bool { get }
    func stop()
    @discardableResult func speak(text: String, voice: String?) -> Bool
}

/// The real AV adapter and an in-memory driver deliver the same utterance
/// identity. A late completion is never evidence about a newer utterance.
@MainActor
protocol SpeechSynthesisPlaybackBackend: AnyObject {
    var isSpeaking: Bool { get }
    var onFinish: ((AVSpeechUtterance) -> Void)? { get set }
    var onCancel: ((AVSpeechUtterance) -> Void)? { get set }
    func stop()
    func prepareUtterance(text: String, voice: String?, defaultLanguageCode: String) -> AVSpeechUtterance
    func speak(_ utterance: AVSpeechUtterance)
}

/// ObjC may call the delegate outside the main actor. Retain the exact
/// utterance until its main-actor completion is delivered; an address alone
/// could be reused after the original utterance is released.
private final class RetainedSpeechUtterance: @unchecked Sendable {
    let value: AVSpeechUtterance

    init(_ value: AVSpeechUtterance) {
        self.value = value
    }
}

@MainActor
final class AVSpeechPlaybackBackend: NSObject, SpeechSynthesisPlaybackBackend, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onFinish: ((AVSpeechUtterance) -> Void)?
    var onCancel: ((AVSpeechUtterance) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func prepareUtterance(text: String, voice: String?, defaultLanguageCode: String) -> AVSpeechUtterance {
        let resolved: AVSpeechSynthesisVoice?
        if let voice {
            // Accept either a language tag or a concrete voice identifier.
            resolved = AVSpeechSynthesisVoice(language: voice)
                ?? AVSpeechSynthesisVoice(identifier: voice)
                ?? AVSpeechSynthesisVoice(language: defaultLanguageCode)
        } else {
            resolved = AVSpeechSynthesisVoice(language: defaultLanguageCode)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolved
        // Slightly slower than default: Chinese TTS reads more naturally
        // at a calmer pace.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        return utterance
    }

    func speak(_ utterance: AVSpeechUtterance) {
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let retained = RetainedSpeechUtterance(utterance)
        Task { @MainActor [weak self, retained] in self?.onFinish?(retained.value) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let retained = RetainedSpeechUtterance(utterance)
        Task { @MainActor [weak self, retained] in self?.onCancel?(retained.value) }
    }
}

// MARK: - Speech Synthesizer (macOS TTS)

/// macOS text-to-speech wrapper around `AVSpeechSynthesizer`.
///
/// Used by the agent's `speech` tool so the assistant can read replies
/// aloud in the desktop app. Everything here is `@MainActor`-isolated:
/// `AVSpeechSynthesizer` is not Sendable and needs a running main run loop.
///
/// Availability notes:
/// - `AVFoundation` (AVFAudio) is fully available on macOS — no extra
///   Info.plist keys are required for **synthesis**.
/// - Idle initialization, state observation, and stop do not create a system
///   speech backend. A valid speak creates it; audible playback still requires
///   the separately verified native output lifecycle.
@MainActor
public final class SpeechSynthesizer: SpeechSynthesisDriving {

    /// Default voice language (BCP-47) when the caller does not specify one.
    public static let defaultLanguage = "zh-CN"

    private var playbackBackend: (any SpeechSynthesisPlaybackBackend)?
    private let makePlaybackBackend: @MainActor () -> any SpeechSynthesisPlaybackBackend

    private var backend: any SpeechSynthesisPlaybackBackend {
        if let playbackBackend { return playbackBackend }
        let created = makePlaybackBackend()
        playbackBackend = created
        installCompletionHandlers(on: created)
        return created
    }
    private let logger = AppLogger(category: "Speech")
    private let defaultLanguageCode: String
    private var activePlayback: AVSpeechUtterance?

    /// The utterance object itself is this playback's generation token. The
    /// delegate retains it across the executor hop before comparing identity.
    var activeGeneration: ObjectIdentifier? { activePlayback.map { ObjectIdentifier($0) } }

    public init() {
        self.defaultLanguageCode = Self.defaultLanguage
        self.makePlaybackBackend = { AVSpeechPlaybackBackend() }
    }

    /// Production initializer driven by `AppSettings.general.language`.
    /// Invalid or missing values fail closed before any utterance is spoken.
    public init(generalLanguage: String?) throws {
        self.defaultLanguageCode = try SpeechLocaleResolver.runtimeLanguage(for: generalLanguage)
        self.makePlaybackBackend = { AVSpeechPlaybackBackend() }
    }

    init(backend: any SpeechSynthesisPlaybackBackend) {
        self.defaultLanguageCode = Self.defaultLanguage
        self.makePlaybackBackend = { backend }
        self.playbackBackend = backend
        installCompletionHandlers(on: backend)
    }

    /// The same deferred creation seam used by the public initializers.
    /// Tests can observe lifecycle effects without initializing system speech.
    init(backendFactory: @escaping @MainActor () -> any SpeechSynthesisPlaybackBackend) {
        self.defaultLanguageCode = Self.defaultLanguage
        self.makePlaybackBackend = backendFactory
    }

    private func installCompletionHandlers(on backend: any SpeechSynthesisPlaybackBackend) {
        backend.onFinish = { [weak self] utterance in self?.complete(utterance) }
        backend.onCancel = { [weak self] utterance in self?.complete(utterance) }
    }

    private func complete(_ utterance: AVSpeechUtterance) {
        guard let activePlayback, activePlayback === utterance else { return }
        self.activePlayback = nil
    }

    /// An accepted utterance remains active while it is queued to start, so
    /// an immediate stop can cancel it even before AV reports isSpeaking.
    public var isSpeaking: Bool {
        activePlayback != nil
    }

    /// Stop active or pending speech immediately (no-op when idle).
    public func stop() {
        guard activePlayback != nil || playbackBackend?.isSpeaking == true else { return }
        activePlayback = nil
        backend.stop()
        logger.info("Speech stopped")
    }

    /// Speak `text` aloud using the voice for `voice` — a BCP-47 language
    /// tag (e.g. `"zh-CN"`, `"en-US"`) or an explicit voice identifier
    /// (e.g. `"com.apple.tts.voice.premium.zh-CN.Tingting"`).
    ///
    /// Falls back to `defaultLanguage` ("zh-CN") when the requested voice
    /// cannot be resolved. Interrupts any speech currently in progress.
    /// Returns `false` (and stays silent) when the text is empty.
    @discardableResult
    public func speak(text: String, voice: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        stop()

        let utterance = backend.prepareUtterance(
            text: trimmed,
            voice: voice,
            defaultLanguageCode: defaultLanguageCode
        )

        activePlayback = utterance
        backend.speak(utterance)
        logger.info("Speaking \(trimmed.count) chars (voice: \(utterance.voice?.identifier ?? "system default"))")
        return true
    }
}
