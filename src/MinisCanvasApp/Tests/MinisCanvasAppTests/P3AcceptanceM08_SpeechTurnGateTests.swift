import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// A fake executor observes only the frozen TaskLocal value. No synthesizer,
/// audio device, or system permission is consulted by this suite.
@Suite("M08 speech effect uses the same turn availability as its catalog")
struct P3AcceptanceM08_SpeechTurnGateTests {
    private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(name: String, authorizedTurnID: String?)] = []

        func execute(name: String, input: [String: Any]) async throws -> String {
            let call: (name: String, authorizedTurnID: String?) = (
                name, SpeechToolExecutionAuthorization.current?.identity.turnID
            )
            lock.withLock { calls.append(call) }
            return "synthetic-output"
        }

        var recordedCalls: [(name: String, authorizedTurnID: String?)] {
            lock.withLock { calls }
        }
    }

    private func availability(voice: Bool?) -> SpeechToolAvailabilitySnapshot {
        SpeechToolAvailabilitySnapshot(
            probe: .init(
                speechLocaleResolved: true,
                ttsVoiceAvailable: voice,
                audioOutputDevicePresent: true
            ),
            sources: .init(
                speechLocaleResolved: .settingsLanguage,
                ttsVoiceAvailable: .systemVoice,
                audioOutputDevicePresent: .audioOutputDevice
            ),
            identity: .init(
                turnID: "synthetic-turn-A",
                capturedAt: Date(timeIntervalSince1970: 1)
            )
        )
    }

    @Test("unsupported or absent turn evidence never reaches the shared speech effect")
    func deniedTurnCannotExecuteSpeech() async throws {
        let base = RecordingExecutor()
        let absent = SpeechAvailabilityGatedToolExecutor(base: base, availability: nil)
        let unknown = SpeechAvailabilityGatedToolExecutor(
            base: base, availability: availability(voice: nil)
        )
        let speechCatalog = AgentToolCatalog.makeTools(
            speechAvailability: availability(voice: true)
        )

        #expect(throws: ToolExecutorError.toolNotConfigured(SpeechTool.toolName)) {
            try absent.validateToolCatalog(speechCatalog)
        }
        #expect(throws: ToolExecutorError.toolNotConfigured(SpeechTool.toolName)) {
            try unknown.validateToolCatalog(speechCatalog)
        }

        await #expect(throws: ToolExecutorError.toolNotConfigured(SpeechTool.toolName)) {
            _ = try await absent.execute(name: SpeechTool.toolName, input: [:])
        }
        await #expect(throws: ToolExecutorError.toolNotConfigured(SpeechTool.toolName)) {
            _ = try await unknown.execute(name: SpeechTool.toolName, input: [:])
        }
        #expect(base.recordedCalls.isEmpty)

        // The speech gate must not disable unrelated native tools.
        #expect(try await absent.execute(name: "file_read", input: [:]) == "synthetic-output")
        let calls = base.recordedCalls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "file_read")
        #expect(calls.first?.authorizedTurnID == nil)
    }

    @Test("supported turn evidence is scoped to one speech effect and then cleared")
    func supportedTurnScopesTaskLocalToEffect() async throws {
        let base = RecordingExecutor()
        let supported = availability(voice: true)
        let gate = SpeechAvailabilityGatedToolExecutor(base: base, availability: supported)

        #expect(supported.isSupported)
        try gate.validateToolCatalog(
            AgentToolCatalog.makeTools(speechAvailability: supported)
        )
        #expect(try await gate.execute(name: SpeechTool.toolName, input: [:]) == "synthetic-output")
        let calls = base.recordedCalls
        #expect(calls.count == 1)
        #expect(calls.first?.name == SpeechTool.toolName)
        #expect(calls.first?.authorizedTurnID == supported.identity.turnID)
        #expect(SpeechToolExecutionAuthorization.current == nil)
    }
}
