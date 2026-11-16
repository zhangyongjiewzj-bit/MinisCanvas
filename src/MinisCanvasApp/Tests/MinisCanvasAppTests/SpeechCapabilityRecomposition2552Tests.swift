import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class ControlledSpeechOutput2552: SpeechSynthesisDriving {
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    var isSpeaking = false

    func speak(text: String, voice: String?) -> Bool {
        spoken.append(text)
        isSpeaking = true
        return true
    }

    func stop() {
        stops += 1
        isSpeaking = false
    }
}

@MainActor
private final class ControlledComposerInput2552: ComposerSpeechInputDriver {
    var configured = true
    var recognizerAvailable = true
    var hasAudioInput = true
    var speechPermission: ComposerSpeechPermission = .granted
    var microphonePermission: ComposerSpeechPermission = .granted
    private(set) var permissionRequests = 0
    private(set) var starts = 0

    func requestAuthorization() async -> Bool {
        permissionRequests += 1
        return false
    }

    func start() throws { starts += 1 }
    func stop() async -> String { "" }
    func cancel() {}
}

/// Recompose the same production Bridge rather than comparing only a pure
/// capability Bool. The controlled output observes the actual SpeechTool
/// effect without using audio hardware or requesting microphone permission.
@Suite("Speech capability after production recomposition 2552")
@MainActor
struct SpeechCapabilityRecomposition2552Tests {
    @Test("new invalid locale removes TTS from catalog and effect, and blocks Composer recording")
    func newConfigurationRejectsBothSpeechEntrypoints() async throws {
        let identity = UUID().uuidString
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let directory = formal.rootDirectory.appendingPathComponent(
            "speech-recomposition-2552-\(identity)", isDirectory: true
        )
        let defaults = try #require(UserDefaults(suiteName: "speech-recomposition-2552.\(identity)"))
        defer {
            defaults.removePersistentDomain(forName: "speech-recomposition-2552.\(identity)")
            try? FileManager.default.removeItem(at: directory)
        }
        let composerInput = ControlledComposerInput2552()
        let bridge = BridgeStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: directory.appendingPathComponent("logs"), ringCapacity: 20),
            sessionDocumentStore: SessionDocumentStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: true, audioOutputDevicePresent: true)
            },
            composerSpeechDriver: composerInput
        )

        let supportedAttach = bridge.attachProductionServices(
            speechGeneralLanguage: "en", sessionDirectory: directory
        )
        await supportedAttach.value
        #expect(bridge.speechRecognizer != nil)
        #expect(bridge.composerSpeechAvailability == .ready)
        #expect(await bridge.startComposerSpeechInput())
        #expect(composerInput.starts == 1)
        bridge.cancelComposerSpeechInput()
        let supported = bridge.prepareSpeechToolAvailability(for: turn(identity, 1))()
        #expect(supported.isSupported)
        #expect(AgentToolCatalog.makeTools(speechAvailability: supported)
            .contains { $0.name == SpeechTool.toolName })

        let output = ControlledSpeechOutput2552()
        let firstBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        firstBuiltin.speech = SpeechTool(synthesizer: output)
        let firstEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let firstGate = SpeechAvailabilityGatedToolExecutor(
            base: firstEngine.composedExecutor, availability: supported
        )
        let started = try await firstGate.execute(name: SpeechTool.toolName, input: [
            "tool_title": "Read synthetic text", "action": "speak", "text": "受控朗读",
        ])
        #expect(started.contains("已开始朗读"))
        #expect(output.spoken == ["受控朗读"])

        // The next composition changes the *actual* recognizer and built-in
        // tool, while the previous turn's captured gate is deliberately left
        // untouched. Await commit before reading the new public consumers.
        let unsupportedAttach = bridge.attachProductionServices(
            speechGeneralLanguage: "not-a-real-language", sessionDirectory: directory
        )
        await unsupportedAttach.value
        let unsupported = bridge.prepareSpeechToolAvailability(for: turn(identity, 2))()
        #expect(unsupported.status == .unsupported(.speechLocaleUnresolved))
        #expect(unsupported.isSupported == false)
        #expect(AgentToolCatalog.makeTools(speechAvailability: unsupported)
            .allSatisfy { $0.name != SpeechTool.toolName })
        #expect(bridge.productionBuiltinToolExecutor?.speech == nil)

        let secondEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let secondGate = SpeechAvailabilityGatedToolExecutor(
            base: secondEngine.composedExecutor, availability: unsupported
        )
        await #expect(throws: ToolExecutorError.toolNotConfigured(SpeechTool.toolName)) {
            _ = try await secondGate.execute(name: SpeechTool.toolName, input: [
                "tool_title": "Must not read", "action": "speak", "text": "不得朗读",
            ])
        }
        #expect(output.spoken == ["受控朗读"])

        #expect(bridge.speechRecognizer == nil)
        // Feed the controlled click driver the recognizer composition fact;
        // its other facts are synthetic, so no microphone or TCC API is read.
        composerInput.configured = bridge.speechRecognizer != nil
        #expect(bridge.composerSpeechAvailability == .unsupported(.speechLocaleUnresolved))
        let draftBefore = bridge.chat.draftText
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(bridge.composerSpeechPhase == .failed(
            ComposerSpeechAvailability.unsupported(.speechLocaleUnresolved).explanation
        ))
        #expect(bridge.chat.draftText == draftBefore)
        #expect(composerInput.permissionRequests == 0)
        #expect(composerInput.starts == 1)
    }

    private func turn(_ identity: String, _ number: Int) -> AgentTurnIdentity {
        AgentTurnIdentity(sessionID: "speech-2552-\(identity)", turnID: number,
                          messageID: "speech-2552-message-\(number)")
    }
}
