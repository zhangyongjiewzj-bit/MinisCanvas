import Foundation
import Testing
@testable import MinisCore

/// Swift folds "\r\n" into ONE `Character` that is neither "\n" nor a plain
/// space, so a Character-level lexer saw `git status\r\nrm -rf x` as one
/// command. The guard now scans Unicode scalars first and rejects the input.
@Suite("TerminalGuard rejects CR, CRLF, Unicode line separators and control characters")
struct TerminalGuardControlCharacterTests {

    @Test("CRLF is a single Swift Character (why a Character-level scan misses it)")
    func crlfIsOneCharacter() {
        #expect(Array("a\r\nb").count == 3)
        #expect(Array("a\r\nb")[1] != "\n")
    }

    @Test("embedded CR, CRLF, U+2028, U+2029, U+0085 and other control characters are rejected")
    func embeddedLineBreaksAreRejected() {
        let commands = [
            "git status\r\nrm -rf x",
            "git status\rrm -rf x",
            "git status\u{2028}rm -rf x",
            "git status\u{2029}rm -rf x",
            "git status\u{85}rm -rf x",
            "git status\u{0B}rm -rf x",
            "git status\u{0C}rm -rf x",
            "git status\u{1B}[31m",
            "git status\u{0}x",
            "echo 'a\rb'",
        ]
        for command in commands {
            let result = TerminalGuard.inspect(command)
            #expect(!result.isAllowed, "\(command.debugDescription)")
            #expect(result.rejectionReason?.isEmpty == false, "\(command.debugDescription)")
        }
    }

    @Test("an ASCII operator followed by a combining mark is rejected instead of read as ordinary text")
    func operatorPlusCombiningMarkIsRejected() {
        for command in ["git status;\u{0301} rm -rf x", "git status &&\u{0301} ls", "git status |\u{0301} cat",
                        "git status \u{0301}x"] {
            #expect(!TerminalGuard.inspect(command).isAllowed, "\(command.debugDescription)")
        }
        // A combining mark after a letter (decomposed text) stays ordinary.
        #expect(TerminalGuard.inspect("echo cafe\u{0301}").isAllowed)
    }

    @Test("existing semantics stay: tab separates words, LF still rejects, outer whitespace is trimmed")
    func existingSemanticsAreKept() {
        #expect(TerminalGuard.inspect("git status").isAllowed)
        let tabbed = TerminalGuard.inspect("git\tstatus")
        #expect(tabbed.isAllowed)
        #expect(tabbed.words == ["git", "status"])
        // Leading/trailing line breaks were always trimmed before lexing.
        #expect(TerminalGuard.inspect("git status\r\n").isAllowed)
        #expect(TerminalGuard.inspect("\r\ngit status").isAllowed)
        let lf = TerminalGuard.inspect("git status\nrm -rf x")
        #expect(!lf.isAllowed)
        #expect(lf.rejectionReason == "newline command separator is not allowed")
    }

    @Test("a CRLF-joined second command no longer rides along as arguments of an allowed command")
    func crlfCompoundIsNotClassifiedAsOneAllowedCommand() {
        let policy = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["git", "ls"], confirmationCommands: [], userDeniedCommands: ["rm"]))
        // Hard-denied name behind the CRLF is recovered by the whole-line scan.
        #expect(policy.classify(command: "git status\r\nrm -rf x") == .denied)
        // A merely unknown follow-up now needs confirmation instead of `.allowed`.
        #expect(policy.classify(command: "git status\r\nls") == .confirmation)
        #expect(policy.classify(command: "git status") == .allowed)
    }
}
