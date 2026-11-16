import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class ControlledTTSDriver2304: SpeechSynthesisDriving {
    private(set) var spoken: [(text: String, voice: String?)] = []
    private(set) var stopCount = 0
    var isSpeaking = false

    func speak(text: String, voice: String?) -> Bool {
        spoken.append((text, voice))
        isSpeaking = true
        return true
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
    }
}

/// Uses the App's real frozen-availability effect gate and the Core speech
/// tool. The driver deliberately never touches an output device.
@Suite("TTS frozen availability production effect 2304")
@MainActor
struct SpeechTTSGate2304Tests {
    @Test("supported turn speaks through the production gate and then stops")
    func supportedSpeakThenStop() async throws {
        let driver = ControlledTTSDriver2304()
        let snapshot = availability(voice: true, output: true)
        let builtin = BuiltinToolExecutor(
            allowedRoot: try allowedRoot(),
            speech: SpeechTool(synthesizer: driver)
        )
        let gate = SpeechAvailabilityGatedToolExecutor(
            base: builtin, availability: snapshot
        )

        #expect(AgentToolCatalog.makeTools(speechAvailability: snapshot)
            .contains { $0.name == SpeechTool.toolName })
        let started = try await gate.execute(name: SpeechTool.toolName, input: [
            "tool_title": "Read this text", "action": "speak", "text": "合成朗读", "voice": "zh-CN",
        ])
        #expect(started.contains("已开始朗读"))
        #expect(driver.spoken.count == 1)
        #expect(driver.spoken.first?.text == "合成朗读")
        #expect(driver.spoken.first?.voice == "zh-CN")
        #expect(driver.isSpeaking)

        let stopped = try await gate.execute(name: SpeechTool.toolName, input: [
            "tool_title": "Stop speaking", "action": "stop",
        ])
        #expect(stopped == "已停止朗读。")
        #expect(driver.stopCount == 1)
        #expect(driver.isSpeaking == false)
    }

    @Test("measured missing device and unknown voice both hide speech and reject effects")
    func unsupportedOrUnknownNeverReachesDriver() async throws {
        for snapshot in [availability(voice: true, output: false),
                         availability(voice: nil, output: true)] {
            let driver = ControlledTTSDriver2304()
            let builtin = BuiltinToolExecutor(
                allowedRoot: try allowedRoot(),
                speech: SpeechTool(synthesizer: driver)
            )
            let gate = SpeechAvailabilityGatedToolExecutor(
                base: builtin, availability: snapshot
            )
            #expect(AgentToolCatalog.makeTools(speechAvailability: snapshot)
                .allSatisfy { $0.name != SpeechTool.toolName })
            await #expect(throws: ToolExecutorError.toolNotConfigured(SpeechTool.toolName)) {
                _ = try await gate.execute(name: SpeechTool.toolName, input: [
                    "tool_title": "Read this text", "action": "speak", "text": "不得播报",
                ])
            }
            #expect(driver.spoken.isEmpty)
            #expect(driver.stopCount == 0)
        }
    }

    private func availability(voice: Bool?, output: Bool?) -> SpeechToolAvailabilitySnapshot {
        SpeechToolAvailabilitySnapshot(
            probe: .init(
                speechLocaleResolved: true,
                ttsVoiceAvailable: voice,
                audioOutputDevicePresent: output
            ),
            sources: .init(
                speechLocaleResolved: .settingsLanguage,
                ttsVoiceAvailable: voice == nil ? .unobserved : .systemVoice,
                audioOutputDevicePresent: output == nil ? .unobserved : .audioOutputDevice
            ),
            identity: .init(turnID: "synthetic-tts-2304", capturedAt: Date(timeIntervalSince1970: 1))
        )
    }

    private func allowedRoot() throws -> URL {
        try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
    }
}
