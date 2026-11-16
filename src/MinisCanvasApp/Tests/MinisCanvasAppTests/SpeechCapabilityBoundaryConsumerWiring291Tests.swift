import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// P3-SPEECH-01 consumer wiring coverage. The `SpeechCapabilityBoundary` model
// already owns the fail-closed decision; these tests prove the *consumers*
// (BridgeStore production seam + the canonical boundary it presents) actually
// route through it deterministically instead of the previous silent `try?` /
// "harmless no-op" semantics. All cases stay device-free: construction never
// speaks, records, or opens audio, and no real microphone/speaker is required.
@Suite("Speech capability boundary consumer wiring (DEV-291)")
@MainActor
struct SpeechCapabilityBoundaryConsumerWiring291Tests {

    private func makeBridge() -> (BridgeStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-boundary-wiring-291-\(UUID().uuidString)")
        return (BridgeStore(), directory)
    }

    // MARK: - Canonical boundary is the single deterministic source of truth

    @Test("unresolved locale fails closed to an explicit presentable reason for both capabilities")
    func unresolvedLocaleFailsClosed() {
        // The seam derives its degradation reason from the pure boundary with
        // only the device-free locale signal set. An unresolved locale must
        // never be upgraded to availability.
        let snapshot = SpeechCapabilityBoundary.evaluate(
            SpeechCapabilityBoundary.Probe(speechLocaleResolved: false)
        )
        #expect(snapshot.textToSpeech == .unsupported(.speechLocaleUnresolved))
        #expect(snapshot.speechRecognition == .unsupported(.speechLocaleUnresolved))
        #expect(snapshot.textToSpeech.isSupported == false)
        #expect(snapshot.speechRecognition.isSupported == false)
    }

    @Test("boundary is deterministic: identical probes yield identical snapshots")
    func boundaryEvaluationIsDeterministic() {
        let probe = SpeechCapabilityBoundary.Probe(
            speechLocaleResolved: true,
            ttsVoiceAvailable: nil,
            audioOutputDevicePresent: nil,
            sttRecognizerPresent: nil,
            sttEngineAvailable: nil,
            speechRecognitionAuthorized: nil,
            microphoneAuthorized: nil,
            audioInputDevicePresent: nil
        )
        #expect(SpeechCapabilityBoundary.evaluate(probe) == SpeechCapabilityBoundary.evaluate(probe))
        // Missing downstream evidence (nil probes) keeps the capability closed
        // rather than pretending it works.
        #expect(SpeechCapabilityBoundary.evaluate(probe).textToSpeech
                    == .unsupported(.noVoiceForEffectiveLocale))
    }

    // MARK: - BridgeStore production seam fails closed

    @Test("invalid speech language fails the seam closed: no recognizer, no tool")
    func invalidLanguageFailsSeamClosed() {
        let (bridge, directory) = makeBridge()
        defer { try? FileManager.default.removeItem(at: directory) }

        bridge.attachProductionServices(
            speechGeneralLanguage: "not-a-real-language",
            sessionDirectory: directory
        )

        // Fail closed: the swallowed `try?` error is now a deterministic nil
        // with an explicit degradation, and the entry is not offered as usable.
        #expect(bridge.speechRecognizer == nil)
        #expect(bridge.productionBuiltinToolExecutor?.speech == nil)
    }

    @Test("degraded seam surfaces toolNotConfigured instead of faking availability")
    func degradedSeamRejectsSpeechInvocation() async throws {
        let (bridge, directory) = makeBridge()
        defer { try? FileManager.default.removeItem(at: directory) }

        bridge.attachProductionServices(
            speechGeneralLanguage: "not-a-real-language",
            sessionDirectory: directory
        )

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        await #expect(throws: (any Error).self) {
            _ = try await engine.composedExecutor.execute(
                name: SpeechTool.toolName,
                input: ["tool_title": "x", "action": "stop"]
            )
        }
    }

    @Test("valid speech language activates the boundary and constructs both consumers")
    func validLanguageActivatesSeam() {
        let (bridge, directory) = makeBridge()
        defer { try? FileManager.default.removeItem(at: directory) }

        bridge.attachProductionServices(
            speechGeneralLanguage: "en",
            sessionDirectory: directory
        )

        // Construction is device-free, so a supported locale produces live
        // objects; availability is still governed by the runtime boundary.
        #expect(bridge.speechRecognizer != nil)
        #expect(bridge.productionBuiltinToolExecutor?.speech != nil)
    }

    @Test("headless no-language path keeps its compatibility behavior")
    func headlessNoLanguagePathUnchanged() {
        let (bridge, directory) = makeBridge()
        defer { try? FileManager.default.removeItem(at: directory) }

        bridge.attachProductionServices(sessionDirectory: directory)

        // No language → recognizer stays nil (recognition is GUI-only) while the
        // synthesizer keeps the default compatibility tool. This existing
        // semantic must not change (P3-SPEECH-01 only fixes the swallowed error).
        #expect(bridge.speechRecognizer == nil)
        #expect(bridge.productionBuiltinToolExecutor?.speech != nil)
    }
}
