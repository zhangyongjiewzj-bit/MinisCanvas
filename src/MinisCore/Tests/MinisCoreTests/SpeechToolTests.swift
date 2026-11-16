import Foundation
import Testing
@testable import MinisCore

// NOTE: This suite runs on the CLT-only toolchain (no Xcode). Swift Testing
// (`import Testing`) is the only runnable test framework — see AgentLoopTests.
//
// Speech tool tests deliberately avoid real audio:
// - AVSpeechSynthesizer output needs a GUI session with speakers.
// - SFSpeechRecognizer needs mic + network (Apple servers) + Info.plist
//   permissions, and is unusable in a headless CLI/CI environment.
// So the suite exercises input parsing, parameter validation and the tool
// definition only — mirroring the BrowserToolTests pattern. The `stop`
// action is headless-safe (it never produces sound) and proves the dispatch
// reached the action switch.

// MARK: - Fixtures

/// Build a tool input dict the way AgentLoop decodes JSON tool calls.
private func input(_ dict: [String: Any]) -> [String: Any] { dict }

@MainActor
private final class ParsingSpeechDriver: SpeechSynthesisDriving {
    private(set) var lastText: String?
    private(set) var lastVoice: String?
    var isSpeaking = false

    func speak(text: String, voice: String?) -> Bool {
        lastText = text
        lastVoice = voice
        isSpeaking = true
        return true
    }

    func stop() { isSpeaking = false }
}

// MARK: - Input parsing & validation (no audio)

@MainActor
struct SpeechToolParsingTests {

    @Test func unknownToolNameThrows() async {
        let tool = SpeechTool()
        await #expect(throws: ToolExecutorError.unknownTool("file_read")) {
            try await tool.execute(name: "file_read", input: input(["action": "speak"]))
        }
    }

    @Test func missingActionThrows() async {
        let tool = SpeechTool()
        await #expect(throws: ToolExecutorError.missingParameter("action")) {
            try await tool.execute(name: "speech", input: input([:]))
        }
        await #expect(throws: ToolExecutorError.missingParameter("action")) {
            try await tool.execute(name: "speech", input: input(["text": "你好"]))
        }
    }

    @Test func unknownActionThrows() async {
        let tool = SpeechTool()
        await #expect(throws: ToolExecutorError.invalidParameter("action=sing")) {
            try await tool.execute(name: "speech", input: input(["action": "sing"]))
        }
    }

    @Test func speakRequiresText() async {
        let tool = SpeechTool()
        await #expect(throws: ToolExecutorError.missingParameter("text")) {
            try await tool.execute(name: "speech", input: input(["action": "speak"]))
        }
        // Whitespace-only text is also rejected.
        await #expect(throws: ToolExecutorError.missingParameter("text")) {
            try await tool.execute(name: "speech", input: input(["action": "speak", "text": "   \n "]))
        }
        // text must be a String (not, e.g., a number).
        await #expect(throws: ToolExecutorError.missingParameter("text")) {
            try await tool.execute(name: "speech", input: input(["action": "speak", "text": 42]))
        }
    }

    @Test func speakAcceptsOptionalVoice() async throws {
        let driver = ParsingSpeechDriver()
        let tool = SpeechTool(synthesizer: driver)
        let output = try await tool.execute(
            name: "speech", input: input(["action": "speak", "text": "你好"])
        )
        #expect(driver.lastText == "你好")
        #expect(driver.lastVoice == nil)
        #expect(output.contains("已开始朗读"))
    }

    @Test func stopDoesNotRequireText() async throws {
        // stop must be accepted without text — proving dispatch reached the
        // action switch (not missingParameter("text")). Headless-safe: it
        // never produces sound.
        let tool = SpeechTool()
        let output = try await tool.execute(name: "speech", input: input(["action": "stop"]))
        #expect(output.contains("朗读"))
    }

    @Test func toolDefinitionIsWellFormed() {
        let definition = SpeechTool.makeDefinition()
        #expect(definition.name == "speech")
        #expect(definition.required.contains("action"))
        #expect(definition.required.contains("tool_title"))
        let action = definition.parameters["action"]
        #expect(action?.type == .string)
        #expect(action?.enumValues?.contains("speak") == true)
        #expect(action?.enumValues?.contains("stop") == true)
        #expect(action?.enumValues?.contains("sing") == false)
        #expect(definition.parameters["text"] != nil)
        #expect(definition.parameters["voice"] != nil)
        #expect(definition.parameters["tool_title"] != nil)
        // Schema conversion smoke checks (provider-agnostic dicts).
        let openAI = definition.openAIFunctionDict
        #expect((openAI["function"] as? [String: Any])?["name"] as? String == "speech")
        let anthropic = definition.anthropicToolDict
        #expect(anthropic["name"] as? String == "speech")
    }
}
