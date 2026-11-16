import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// Production speech coverage stays headless: action=stop validates composition
// and dispatch without speaking, opening audio, or requesting microphone access.
@Suite("Speech production consumer")
@MainActor
struct SpeechProductionConsumerTests {

    @Test("production composition injects SpeechTool and dispatches headless stop")
    func productionCompositionInjectsSpeechTool() async throws {
        let bridge = BridgeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-production-consumer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        bridge.attachProductionServices(sessionDirectory: directory)

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let gate = SpeechAvailabilityGatedToolExecutor(
            base: engine.composedExecutor, availability: availability(voice: true)
        )
        let output = try await gate.execute(
            name: SpeechTool.toolName,
            input: ["action": "stop"]
        )

        #expect(output.contains("朗读"))
    }

    @Test("headless speech stop does not require text or audio")
    func headlessSpeechStopRequiresNoText() async throws {
        let bridge = BridgeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-stop-consumer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        bridge.attachProductionServices(sessionDirectory: directory)

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let gate = SpeechAvailabilityGatedToolExecutor(
            base: engine.composedExecutor, availability: availability(voice: true)
        )
        let output = try await gate.execute(
            name: SpeechTool.toolName,
            input: [
                "tool_title": "Stop speaking",
                "action": "stop",
            ]
        )

        #expect(output == "当前没有正在进行的朗读。")
    }

    @Test("missing or unknown frozen evidence rejects even headless stop")
    func unobservedSpeechStopFailsClosed() async throws {
        let bridge = BridgeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-denied-consumer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        bridge.attachProductionServices(sessionDirectory: directory)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        for snapshot in [nil, availability(voice: nil)] as [SpeechToolAvailabilitySnapshot?] {
            let gate = SpeechAvailabilityGatedToolExecutor(
                base: engine.composedExecutor, availability: snapshot
            )
            await #expect(throws: ToolExecutorError.toolNotConfigured(SpeechTool.toolName)) {
                _ = try await gate.execute(name: SpeechTool.toolName, input: ["action": "stop"])
            }
        }
        // This call bypasses the frozen gate and reaches the production runner.
        // Its absent TaskLocal still denies the effect; ConcurrentToolRunner
        // transports the localized refusal and the limiting wrapper rethrows
        // that exact reason as invalidParameter. The gate assertions above
        // retain their distinct, original typed toolNotConfigured contract.
        let composed = try #require(engine.composedExecutor as? ConcurrentToolLimitingExecutor)
        #expect(SpeechToolExecutionAuthorization.current == nil)
        await #expect(throws: ToolExecutorError.invalidParameter(
            "工具尚未配置执行器：speech"
        )) {
            _ = try await composed.execute(
                name: SpeechTool.toolName, input: ["action": "stop"]
            )
        }
        #expect(SpeechToolExecutionAuthorization.current == nil)
    }

    /// Synthetic frozen observations drive the real production gate; stop
    /// never opens audio or asks the host to measure voice/device availability.
    private func availability(voice: Bool?) -> SpeechToolAvailabilitySnapshot {
        SpeechToolAvailabilitySnapshot(
            probe: .init(
                speechLocaleResolved: true, ttsVoiceAvailable: voice,
                audioOutputDevicePresent: true
            ),
            sources: .init(
                speechLocaleResolved: .settingsLanguage,
                ttsVoiceAvailable: .systemVoice,
                audioOutputDevicePresent: .audioOutputDevice
            ),
            identity: .init(
                turnID: "synthetic-production-speech-stop",
                capturedAt: Date(timeIntervalSince1970: 1)
            )
        )
    }

}
