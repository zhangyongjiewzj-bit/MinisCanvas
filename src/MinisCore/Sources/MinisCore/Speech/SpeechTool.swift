import Foundation

// MARK: - Speech Tool

/// Agent tool exposing macOS text-to-speech to the model.
///
/// Implements `ToolExecutor` (B1b protocol) for `name == "speech"` with
/// `input.action` ∈ { speak, stop }:
///   - speak: `text` (required), `voice` (optional — BCP-47 language tag
///     like `"zh-CN"` (default) / `"en-US"`, or a voice identifier)
///   - stop:  (no parameters — interrupts ongoing speech)
///
/// Headless-safe by construction: parsing and parameter validation are pure
/// and never touch audio; only a valid `speak` call reaches the real
/// `AVSpeechSynthesizer`, which needs a GUI session to be audible (safe
/// no-op otherwise). Speech **recognition** is deliberately not exposed as
/// an action — it needs mic + Apple servers + Info.plist permissions
/// (`NSSpeechRecognitionUsageDescription`, `NSMicrophoneUsageDescription`)
/// and belongs to the app layer / a later iteration (`SpeechRecognizer`).
///
/// Concurrency shape mirrors `BrowserTool`: `execute` is nonisolated (pure
/// parse/validate), then hops to `@MainActor` only to touch the synthesizer.
public struct SpeechTool: ToolExecutor, Sendable {

    /// Canonical tool name the model calls.
    public static let toolName = "speech"

    /// The TTS engine backing this tool.
    public let synthesizer: any SpeechSynthesisDriving

    public init(synthesizer: any SpeechSynthesisDriving) {
        self.synthesizer = synthesizer
    }

    /// Convenience init — creates a fresh synthesizer (main-actor hop).
    @MainActor
    public init() {
        self.init(synthesizer: SpeechSynthesizer())
    }

    /// Production initializer driven by `AppSettings.general.language`.
    @MainActor
    public init(generalLanguage: String?) throws {
        self.init(synthesizer: try SpeechSynthesizer(generalLanguage: generalLanguage))
    }

    // MARK: ToolExecutor (nonisolated entry — parse & validate only)

    public func execute(name: String, input: [String: Any]) async throws -> String {
        guard name == Self.toolName else {
            throw ToolExecutorError.unknownTool(name)
        }
        let parsed = try Self.parse(input: input)
        let synthesizer = self.synthesizer
        return await Self.run(synthesizer: synthesizer, parsed: parsed)
    }

    // MARK: - Parsing (pure, nonisolated)

    /// Fully validated action input. Sendable so it can cross into the
    /// `@MainActor` execution layer.
    private struct ParsedInput: Sendable {
        let action: String
        let text: String?
        let voice: String?
    }

    private static func parse(input: [String: Any]) throws -> ParsedInput {
        guard let action = input["action"] as? String, !action.isEmpty else {
            throw ToolExecutorError.missingParameter("action")
        }
        let parsed = ParsedInput(
            action: action,
            text: input["text"] as? String,
            voice: input["voice"] as? String
        )
        // Per-action parameter validation.
        switch action {
        case "speak":
            guard let text = parsed.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolExecutorError.missingParameter("text")
            }
        case "stop":
            break
        default:
            throw ToolExecutorError.invalidParameter("action=\(action)")
        }
        return parsed
    }

    // MARK: - Execution (@MainActor — touches AVSpeechSynthesizer)

    @MainActor
    private static func run(synthesizer: any SpeechSynthesisDriving, parsed: ParsedInput) async -> String {
        switch parsed.action {
        case "speak":
            let text = parsed.text! // validated in parse()
            let started = synthesizer.speak(text: text, voice: parsed.voice)
            return started
                ? "已开始朗读（\(text.count) 字）。如需停止，调用 speech action=stop。"
                : "朗读未开始：文本为空或语音不可用。"
        case "stop":
            let wasSpeaking = synthesizer.isSpeaking
            synthesizer.stop()
            return wasSpeaking ? "已停止朗读。" : "当前没有正在进行的朗读。"
        default:
            // Unreachable — parse() rejects unknown actions.
            return "未知 action：\(parsed.action)"
        }
    }

    // MARK: - Tool definition (for AgentToolCatalog)

    /// Canonical tool schema for the model. Register via
    /// `AgentToolCatalog.makeTools()` / compose into
    /// `AgentContext.toolExecutor` alongside `BrowserTool` (B1b wiring).
    public static func makeDefinition() -> AgentToolDefinition {
        AgentToolDefinition(
            name: toolName,
            description: "Read text aloud to the user through the Mac's speech output, and stop it. Use only when the user asks to hear something or has turned on spoken replies; do not narrate routine work. Text is spoken as written, so strip markup and keep it short. action=speak needs text and an optional voice; action=stop interrupts current speech. The result says whether speech started or stopped; if audio output is unavailable the call reports the reason instead of silently doing nothing. This tool only outputs speech; it cannot listen or transcribe.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Short summary in the user's language, e.g. \"Read reply aloud\"."),
                "action": AgentToolParam(type: .string, description: "speak: read text aloud; stop: interrupt current speech.", enumValues: ["speak", "stop"]),
                "text": AgentToolParam(type: .string, description: "speak only, required: plain text to read (no markup)."),
                "voice": AgentToolParam(type: .string, description: "speak only, optional: language tag such as zh-CN (default) or en-US, or an exact voice identifier."),
            ],
            required: ["tool_title", "action"],
            propertyOrdering: ["tool_title", "action", "text", "voice"]
        )
    }
}
