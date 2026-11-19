import Foundation
import Testing
@testable import MinisCore

@Suite("D-SPEECHC model catalog availability")
struct P3AcceptanceM07SpeechCatalogTests {
    // Approved N-02 adds the session-local todo_write tool; speech evidence rules stay unchanged.
    private let ordinaryNames = [
        "file_grep", "file_glob", "todo_write", "shell_execute", "shell_output", "shell_stop", "file_read", "file_write", "file_edit", "file_delete",
        "session_read", "external_session_read", "external_session_send",
        // 会话之间的协作（用户 2026-11-16）：给其它会话发消息、共享任务看板。
        "session_send", "task_board", "context_compact", "browser",
    ]

    private func availability(voiceAvailable: Bool?) -> SpeechToolAvailabilitySnapshot {
        SpeechToolAvailabilitySnapshot(
            probe: SpeechCapabilityBoundary.Probe(
                speechLocaleResolved: true,
                ttsVoiceAvailable: voiceAvailable,
                audioOutputDevicePresent: true
            ),
            sources: .init(
                speechLocaleResolved: .settingsLanguage,
                ttsVoiceAvailable: .systemVoice,
                audioOutputDevicePresent: .audioOutputDevice
            ),
            identity: .init(
                turnID: "synthetic-catalog-turn",
                capturedAt: Date(timeIntervalSince1970: 1)
            )
        )
    }

    @Test("missing and unknown turn evidence never advertise speech")
    func missingOrUnknownSnapshotDisablesSpeech() {
        let unknown = availability(voiceAvailable: nil)
        #expect(!unknown.isSupported)
        #expect(unknown.isUnknown)
        #expect(unknown.unknownFields.contains(.ttsVoiceAvailable))
        #expect(unknown.unsupportedReason == nil)
        #expect(AgentToolCatalog.makeTools().map(\.name) == ordinaryNames)
        #expect(AgentToolCatalog.makeTools(speechAvailability: unknown).map(\.name) == ordinaryNames)
    }

    @Test("supported frozen TTS evidence advertises one speech tool and preserves other tools")
    func supportedSnapshotAdvertisesSpeechExactlyOnce() throws {
        let supported = availability(voiceAvailable: true)
        #expect(supported.isSupported)
        #expect(!supported.isUnknown)
        #expect(supported.unsupportedReason == nil)

        let tools = AgentToolCatalog.makeTools(speechAvailability: supported)
        #expect(tools.map(\.name) == ordinaryNames + [SpeechTool.toolName])
        let speech = try #require(tools.first { $0.name == SpeechTool.toolName })
        #expect(speech.required == SpeechTool.makeDefinition().required)
        #expect(tools.filter { $0.name == SpeechTool.toolName }.count == 1)
    }

    @Test("unsupported TTS remains hidden through orchestration and async catalog composition")
    func unsupportedSnapshotRemainsHiddenInComposedCatalog() async throws {
        let unsupported = availability(voiceAvailable: false)
        #expect(!unsupported.isSupported)
        #expect(!unsupported.isUnknown)
        #expect(unsupported.unsupportedReason == .noVoiceForEffectiveLocale)
        let orchestration = AgentToolDefinition(
            name: "orchestrate", description: "Synthetic optional tool",
            parameters: [:], required: []
        )

        let synchronous = AgentToolCatalog.makeTools(
            orchestration: orchestration, speechAvailability: unsupported
        )
        #expect(synchronous.map(\.name) == ordinaryNames + ["orchestrate", "child_result"])

        let asynchronous = try await AgentToolCatalog.makeTools(
            includingMCPFrom: nil,
            orchestration: orchestration,
            speechAvailability: unsupported
        )
        #expect(asynchronous.map(\.name) == synchronous.map(\.name))
    }
}
