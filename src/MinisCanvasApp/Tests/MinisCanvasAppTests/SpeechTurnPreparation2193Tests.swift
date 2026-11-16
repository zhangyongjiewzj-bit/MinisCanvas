import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class SpeechProbeThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [(String, Bool)] = []

    func observe(_ language: String) -> SpeechToolDirectObservations {
        lock.withLock { observations.append((language, Thread.isMainThread)) }
        return SpeechToolDirectObservations(
            voiceAvailable: true, audioOutputDevicePresent: true
        )
    }

    var captured: [(String, Bool)] { lock.withLock { observations } }
}

@Suite("Speech turn preparation stays off the UI actor")
@MainActor
struct SpeechTurnPreparation2193Tests {
    @Test("production turn freezes real probe facts without querying on the UI thread")
    func productionSpeechProbeRunsOffMain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-preparation-2193-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = SpeechProbeThreadRecord()
        let bridge = BridgeStore(speechToolDirectObservationProvider: record.observe)
        await bridge.attachProductionServices(
            speechGeneralLanguage: "en", sessionDirectory: directory,
            externalNetworkAllowed: false
        ).value

        let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let turn = AgentTurnIdentity(
            sessionID: "speech-2193", turnID: 1, messageID: "assistant-2193"
        )
        let pending = factory(turn, MockProvider.shared)
        #expect(record.captured.isEmpty)
        let prepared = try #require(await pending.preparedForExecution())
        let availability = try #require(prepared.speechToolAvailability)

        #expect(record.captured.count == 1)
        #expect(record.captured.first?.0 == "en-US")
        #expect(record.captured.first?.1 == false)
        #expect(availability.identity.turnID == "chat:speech-2193:1:assistant-2193")
        #expect(availability.probe.ttsVoiceAvailable == true)
        #expect(availability.probe.audioOutputDevicePresent == true)
    }

    @Test("missing language stays unknown and never queries the native producer")
    func missingLanguageKeepsUnknown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-unknown-2193-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = SpeechProbeThreadRecord()
        let bridge = BridgeStore(speechToolDirectObservationProvider: record.observe)
        await bridge.attachProductionServices(
            sessionDirectory: directory, externalNetworkAllowed: false
        ).value

        let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let pending = factory(
            AgentTurnIdentity(sessionID: "speech-unknown", turnID: 2, messageID: "assistant-2"),
            MockProvider.shared
        )
        let prepared = try #require(await pending.preparedForExecution())
        let availability = try #require(prepared.speechToolAvailability)
        #expect(record.captured.isEmpty)
        #expect(availability.probe.ttsVoiceAvailable == nil)
        #expect(availability.probe.audioOutputDevicePresent == nil)
    }
}
