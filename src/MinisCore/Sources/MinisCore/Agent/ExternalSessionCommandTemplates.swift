import Foundation

/// Declarative command templates for `external_session_send`.
///
/// One row per supported external agent. The tool never concatenates CLI
/// sub-commands: `source` selects a row, the row yields a fixed argv, and the
/// message travels only through stdin (never argv, never a shell string).
struct ExternalSessionCommandTemplate: Sendable {
    /// `codex` | `claude_code`.
    let source: String
    /// Absolute path candidates; `$HOME` is expanded at resolution time and the
    /// first executable candidate wins. PATH is deliberately not consulted: the
    /// sanitized child PATH does not contain `~/.local/bin`.
    let binaryCandidates: [String]
    let argv: @Sendable (_ sessionID: String) -> [String]
    let messageViaStdin: Bool

    static let codex = ExternalSessionCommandTemplate(
        source: "codex",
        binaryCandidates: [
            "/opt/homebrew/bin/codex",
            "$HOME/.local/bin/codex",
            "/usr/local/bin/codex"
        ],
        // `-` makes `codex exec resume` read the prompt from stdin.
        argv: { ["exec", "resume", "--all", $0, "-"] },
        messageViaStdin: true
    )

    static let claudeCode = ExternalSessionCommandTemplate(
        source: "claude_code",
        binaryCandidates: [
            "$HOME/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ],
        // `-p` without a positional prompt reads the prompt from stdin.
        argv: { ["-p", "--resume", $0] },
        messageViaStdin: true
    )

    static let all: [ExternalSessionCommandTemplate] = [codex, claudeCode]

    /// Only the table's own keys are valid sources.
    static func template(for source: String) -> ExternalSessionCommandTemplate? {
        all.first { $0.source == source }
    }

    /// Argument fragments that widen the peer agent's permissions. No template
    /// may produce them; the tool re-checks every argv before spawning.
    static let forbiddenArgumentFragments: [String] = [
        "--dangerously", "--yolo", "bypassPermissions", "bypass-approvals",
        "--permission-mode", "--sandbox", "--full-auto", "danger-full-access",
        "--allow-dangerously-skip-permissions"
    ]

    static func containsForbiddenArgument(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            forbiddenArgumentFragments.contains { argument.contains($0) }
        }
    }

    /// First executable candidate, or nil. `isExecutable` is injectable so the
    /// resolution order can be tested against a synthetic directory.
    func resolveBinary(
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for candidate in binaryCandidates {
            let path = candidate.hasPrefix("$HOME")
                ? home + String(candidate.dropFirst("$HOME".count))
                : candidate
            if path.hasPrefix("/"), isExecutable(path) { return path }
        }
        return nil
    }
}
