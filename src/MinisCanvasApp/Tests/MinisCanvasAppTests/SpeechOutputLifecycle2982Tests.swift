import AVFoundation
import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("App TTS output lifecycle 2982")
@MainActor
struct SpeechOutputLifecycle2982Tests {
    @Test("production gate playback stops on its App lifecycle and rejects old callbacks",
          arguments: ["session", "rebind", "quit"])
    func appLifecycleStopsOwnedPlayback(trigger: String) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let identity = UUID().uuidString
        let directory = formal.rootDirectory.appendingPathComponent("tts-lifecycle-2982-\(identity)")
        let suite = "tts-lifecycle-2982.\(identity)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let bridge = BridgeStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: directory.appendingPathComponent("logs"), ringCapacity: 20),
            workflowStore: WorkflowStore(storeDirectory: directory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: directory.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: directory),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: directory),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: true, audioOutputDevicePresent: true)
            }
        )
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        await bridge.attachProductionServices(speechGeneralLanguage: "en", sessionDirectory: directory).value
        let backend = ControlledPlaybackBackend2982()
        // Use the real synthesizer facade, not a substitute SpeechSynthesisDriving.
        let synthesizer = SpeechSynthesizer(backend: backend)
        let firstBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        firstBuiltin.speech = SpeechTool(synthesizer: synthesizer)
        let initialSession = try #require(bridge.chat.activeSessionID)
        let initialMessages = bridge.chat.messages.count
        bridge.chat.draftText = "TTS不得改草稿"
        let firstGate = try gate(bridge, session: initialSession, turn: 1)
        let started = try await firstGate.execute(name: "speech", input: [
            "tool_title": "Read first owned reply", "action": "speak", "text": "旧会话朗读",
        ])
        #expect(started.contains("已开始朗读"))
        let oldUtterance = try #require(backend.current)
        // The facade must own queued playback before hardware isSpeaking.
        #expect(backend.isSpeaking == false)
        #expect(synthesizer.isSpeaking)
        #expect(backend.stops == 0)

        switch trigger {
        case "session":
            bridge.chat.newSession()
            #expect(bridge.chat.activeSessionID != initialSession)
        case "rebind":
            await bridge.attachProductionServices(speechGeneralLanguage: "en", sessionDirectory: directory).value
        default:
            let lifecycle = AppLifecycleGuard.beginAtLaunch(defaults: defaults)
            let delegate = MinisCanvasAppDelegate()
            lifecycle.bind(appDelegate: delegate, bridge: bridge)
            delegate.applicationWillTerminate(Notification(name: Notification.Name("synthetic-will-terminate")))
            #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey))
        }
        #expect(backend.stops == 1, "App transition must stop the already accepted utterance")
        #expect(synthesizer.isSpeaking == false)
        #expect(synthesizer.activeGeneration == nil)
        if trigger != "session" {
            #expect(bridge.chat.draftText == "TTS不得改草稿")
            #expect(bridge.chat.messages.count == initialMessages)
        }
        if trigger == "quit" {
            backend.onFinish?(oldUtterance)
            backend.onCancel?(oldUtterance)
            #expect(synthesizer.isSpeaking == false)
            #expect(backend.stops == 1)
            return
        }

        // The next App consumer reuses the same real facade after old playback
        // was stopped; callbacks retain the old utterance's object identity.
        let nextBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        nextBuiltin.speech = SpeechTool(synthesizer: synthesizer)
        let nextSession = try #require(bridge.chat.activeSessionID)
        let nextGate = try gate(bridge, session: nextSession, turn: 2)
        let second = try await nextGate.execute(name: "speech", input: [
            "tool_title": "Read replacement reply", "action": "speak", "text": "替代朗读",
        ])
        #expect(second.contains("已开始朗读"))
        let nextGeneration = try #require(synthesizer.activeGeneration)
        backend.onFinish?(oldUtterance)
        backend.onCancel?(oldUtterance)
        #expect(synthesizer.activeGeneration == nextGeneration)
        #expect(synthesizer.isSpeaking)
        #expect(backend.stops == 1)
        let stopped = try await nextGate.execute(name: "speech", input: [
            "tool_title": "Stop replacement reply", "action": "stop",
        ])
        #expect(stopped == "已停止朗读。")
        #expect(backend.stops == 2)
        #expect(synthesizer.isSpeaking == false)
    }

    private func gate(_ bridge: BridgeStore, session: UUID, turn: Int) throws -> SpeechAvailabilityGatedToolExecutor {
        let snapshot = bridge.prepareSpeechToolAvailability(for: AgentTurnIdentity(
            sessionID: session.uuidString, turnID: turn, messageID: "tts-2982-\(turn)"
        ))()
        #expect(snapshot.isSupported)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        return SpeechAvailabilityGatedToolExecutor(base: engine.composedExecutor, availability: snapshot)
    }
}

/// Existing Core playback seam; no output-device query or AV synthesizer
/// playback. AVSpeechUtterance supplies the real facade's identity token.
@MainActor
private final class ControlledPlaybackBackend2982: SpeechSynthesisPlaybackBackend {
    var isSpeaking = false
    var onFinish: ((AVSpeechUtterance) -> Void)?
    var onCancel: ((AVSpeechUtterance) -> Void)?
    private(set) var current: AVSpeechUtterance?
    private(set) var stops = 0
    func prepareUtterance(text: String, voice: String?, defaultLanguageCode: String) -> AVSpeechUtterance {
        AVSpeechUtterance(string: text)
    }
    func speak(_ utterance: AVSpeechUtterance) { current = utterance }
    func stop() { stops += 1; current = nil; isSpeaking = false }
}
