import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Batch2T terminal interactive program hint")
struct Batch2TTerminalInteractiveHintTests {
    @Test("interactive programs get a Chinese hint", arguments: [
        "claude code", "claude", "vim a.txt", "python3", "top",
        "FOO=1 sudo /usr/bin/vim x", "ssh host", "node", "sqlite3 a.db",
    ])
    func interactiveGivesHint(_ line: String) {
        let hint = TerminalInteractiveProgramHint.hint(for: line)
        #expect(hint?.hasPrefix("此面板暂不支持交互式程序（") == true)
        #expect(hint?.contains("claude -p") == true)
    }

    @Test("hint names the program")
    func hintNamesProgram() {
        #expect(TerminalInteractiveProgramHint.hint(for: "claude code")?.contains("（claude）") == true)
        #expect(TerminalInteractiveProgramHint.hint(for: "/usr/bin/vim a")?.contains("（vim）") == true)
    }

    @Test("non-interactive forms get no hint", arguments: [
        "claude -p \"hi\"", "echo hi | claude -p", "python3 script.py",
        "python3 -c 'print(1)'", "ls -la", "git status", "ssh host ls",
        "emacs --batch -l x.el", "psql -c 'select 1'", "sqlite3 a.db 'select 1'",
    ])
    func nonInteractiveNoHint(_ line: String) {
        #expect(TerminalInteractiveProgramHint.hint(for: line) == nil)
    }
}
