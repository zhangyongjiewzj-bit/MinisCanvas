import Testing
@testable import MinisCore

@MainActor
private final class InMemorySpeechDriver: SpeechSynthesisDriving {
    private(set) var spoken: [(text: String, voice: String?)] = []
    private(set) var stopCount = 0
    var isSpeaking = false
    var acceptsSpeech = true

    func speak(text: String, voice: String?) -> Bool {
        spoken.append((text, voice))
        if acceptsSpeech { isSpeaking = true }
        return acceptsSpeech
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
    }
}

/// P3-SPEECH-01 non-device evidence for TTS entry and control. Audible output
/// and a real device still require the separately authorized App journey.
@Suite("M08 speech tool output control")
@MainActor
struct P3AcceptanceM08_TTSControlTests {
    @Test("speak routes text and voice to the output driver; stop interrupts it")
    func speakThenStopUsesOutputDriver() async throws {
        let driver = InMemorySpeechDriver()
        let tool = SpeechTool(synthesizer: driver)

        let start = try await tool.execute(name: "speech", input: [
            "action": "speak", "text": "读这句话", "voice": "zh-CN",
        ])
        #expect(start.contains("已开始朗读"))
        #expect(driver.spoken.count == 1)
        #expect(driver.spoken.first?.text == "读这句话")
        #expect(driver.spoken.first?.voice == "zh-CN")
        #expect(driver.isSpeaking)

        let stopped = try await tool.execute(name: "speech", input: ["action": "stop"])
        #expect(stopped == "已停止朗读。")
        #expect(driver.stopCount == 1)
        #expect(driver.isSpeaking == false)
    }

    @Test("an output driver refusal is not reported as successful speech")
    func rejectedOutputDoesNotClaimSpeechStarted() async throws {
        let driver = InMemorySpeechDriver()
        driver.acceptsSpeech = false
        let tool = SpeechTool(synthesizer: driver)

        let output = try await tool.execute(name: "speech", input: [
            "action": "speak", "text": "unavailable",
        ])
        #expect(output == "朗读未开始：文本为空或语音不可用。")
        #expect(driver.spoken.count == 1)
        #expect(driver.isSpeaking == false)
        #expect(driver.stopCount == 0)
    }
}
