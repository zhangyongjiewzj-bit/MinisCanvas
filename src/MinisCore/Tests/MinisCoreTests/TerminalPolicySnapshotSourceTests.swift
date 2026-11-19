import Foundation
import Testing
@testable import MinisCore

/// D-TERMINAL-03/04 (F07) contract: the right-side terminal and Agent
/// `shell_execute` classify commands from ONE immutable snapshot source, and
/// product hard-deny entries are never removable or launderable by any
/// settings shape — interactive edit, persisted decode, domain reset, or an
/// in-flight turn racing a later settings edit.
///
/// Both production consumers call exactly two public entry points on
/// `TerminalPolicySnapshot`:
/// - visible terminal: `classify(command:)` (TerminalGuard/ContextPanelView
///   and `TerminalPolicy.decision`)
/// - Agent `shell_execute`: `TerminalGuard.inspect` +
///   `classify(words:syntaxAllowed:)` (BuiltinToolExecutor.runShell)
/// These tests pin the two entry points to the same classification facts.
@Suite("D-TERMINAL-03/04 terminal policy single snapshot source")
struct TerminalPolicySnapshotSourceTests {

    private static var hardDenied: [String] {
        TerminalPolicySnapshot.productHardDeniedCommands.sorted()
    }

    // MARK: D-TERMINAL-03 — product hard-deny items are not removable

    @Test("hard-deny survives empty, reset, and default settings shapes")
    func hardDenySurvivesEveryUserEditShape() {
        let emptied = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: [],
            confirmationCommands: [],
            userDeniedCommands: []
        ))
        for command in Self.hardDenied {
            #expect(emptied.classify(command: command) == .denied)
            #expect(emptied.productHardDeniedCommands
                == TerminalPolicySnapshot.productHardDeniedCommands)
        }

        // The shipped default is the "restore defaults" outcome; it must not
        // list any hard-deny name in an editable region either.
        let defaults = TerminalPolicySettings.default
        #expect(Set(defaults.automaticAllowCommands)
            .isDisjoint(with: TerminalPolicySnapshot.productHardDeniedCommands))
        #expect(Set(defaults.confirmationCommands)
            .isDisjoint(with: TerminalPolicySnapshot.productHardDeniedCommands))
        #expect(Set(defaults.userDeniedCommands)
            .isDisjoint(with: TerminalPolicySnapshot.productHardDeniedCommands))
    }

    @Test("hard-deny names cannot be laundered into allow or confirm lists")
    func hardDenyCannotBeLaunderedIntoEditableLists() {
        let laundered = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo", "halt", "reboot"],
            confirmationCommands: ["git", "dd"],
            userDeniedCommands: ["shutdown"]
        ))
        #expect(!laundered.automaticAllowCommands.contains("halt"))
        #expect(!laundered.automaticAllowCommands.contains("reboot"))
        #expect(!laundered.confirmationCommands.contains("dd"))
        // userDenied is also kept disjoint from the hard set; the hard set is
        // never sourced from user data, so removing those entries cannot
        // shrink it.
        #expect(!laundered.userDeniedCommands.contains("shutdown"))
        #expect(laundered.productHardDeniedCommands
            == TerminalPolicySnapshot.productHardDeniedCommands)
        #expect(laundered.classify(command: "halt ls") == .denied)
        #expect(laundered.classify(command: "reboot My.app") == .denied)
        #expect(laundered.classify(command: "echo still-mine") == .allowed)
    }

    @Test("a persisted settings blob decodes with the hard-deny invariant enforced")
    func persistedSettingsDecodeStripsHardDeniedEntries() throws {
        // Same shape `TerminalPolicySettings` writes on disk, but crafted so a
        // tampered or legacy file tries to place hard-deny names into every
        // editable list. Decoding must restore the exact invariant the
        // interactive SettingsCenter setter enforces.
        let json = """
        {"automaticAllowCommands":["echo","halt","ls","dd"],\
        "confirmationCommands":["git","reboot"],\
        "userDeniedCommands":["shutdown","printf"]}
        """
        let settings = try JSONDecoder().decode(
            TerminalPolicySettings.self,
            from: Data(json.utf8)
        )
        let hard = TerminalPolicySnapshot.productHardDeniedCommands
        #expect(Set(settings.automaticAllowCommands).isDisjoint(with: hard))
        #expect(Set(settings.confirmationCommands).isDisjoint(with: hard))
        #expect(Set(settings.userDeniedCommands).isDisjoint(with: hard))
        // Legitimate user entries survive; this is strip-only, not wipe.
        #expect(settings.automaticAllowCommands.contains("echo"))
        #expect(settings.automaticAllowCommands.contains("ls"))
        #expect(settings.confirmationCommands.contains("git"))
        #expect(settings.userDeniedCommands.contains("printf"))

        // The decoded value now equals what the interactive setter would have
        // persisted, so settings mirror, UI editor text, and the consumed
        // snapshot can never disagree about a hard-deny name.
        let snapshot = TerminalPolicySnapshot(settings: settings)
        #expect(snapshot.classify(command: "halt ls") == .denied)
        #expect(snapshot.classify(command: "dd if=/dev/zero") == .denied)
        #expect(snapshot.classify(command: "reboot X.app") == .denied)
        #expect(snapshot.classify(command: "echo ok") == .allowed)
    }

    @Test("snapshot JSON round-trips with stable revision and hard set")
    func snapshotDecodeRoundTripKeepsHardDenyAndRevision() throws {
        let original = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo", "halt"],
            confirmationCommands: ["git"],
            userDeniedCommands: ["printf"]
        ))
        let data = try JSONEncoder().encode(original)
        // The persisted snapshot payload must not carry a hard-deny list at
        // all; the set is a Core constant re-derived on every decode.
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(payload["productHardDeniedCommands"] == nil)

        let decoded = try JSONDecoder().decode(TerminalPolicySnapshot.self, from: data)
        #expect(decoded.revision == original.revision)
        #expect(decoded.productHardDeniedCommands
            == TerminalPolicySnapshot.productHardDeniedCommands)
        #expect(decoded.classify(command: "git status") == original.classify(command: "git status"))
        #expect(decoded.classify(command: "halt ls") == .denied)
    }

    // MARK: D-TERMINAL-04 — both consumers classify from the same snapshot

    @Test("terminal and Agent classify entry points agree on every simple command")
    func bothConsumerEntryPointsAgreeOnSimpleCommands() throws {
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo", "ls", "pwd"],
            confirmationCommands: ["git", "rm"],
            userDeniedCommands: ["printf"]
        ))
        let battery: [(command: String, expected: TerminalCommandDisposition)] = [
            ("ls", .allowed),
            ("echo hi", .allowed),
            ("/bin/pwd", .allowed),
            ("git status", .allowed),
            ("git commit -m x", .confirmation),
            ("git push", .confirmation),
            ("rm note.txt", .confirmation),
            ("printf ok", .denied),
            ("reboot My.app", .denied),
            ("halt Finder", .denied),
            ("qqqnotacommand", .unknown),
        ]
        for probe in battery {
            // Visible terminal entry point (TerminalGuard.classify / TerminalPolicy.decision).
            let viaTerminal = snapshot.classify(command: probe.command)
            #expect(viaTerminal == probe.expected, "terminal view of \(probe.command)")
            // Agent `shell_execute` entry point (runShell guards syntax first,
            // then classifies the guarded words).
            let inspected = TerminalGuard.inspect(probe.command)
            if inspected.isAllowed {
                let viaAgent = snapshot.classify(words: inspected.words, syntaxAllowed: true)
                #expect(viaAgent == probe.expected, "agent view of \(probe.command)")
                #expect(viaAgent == viaTerminal, "single-source divergence for \(probe.command)")
            } else {
                // The structural guard may block a command before any shared
                // classification (e.g. command wrappers). That is the separate
                // documented syntax gate, never a second command-category
                // source, so it must not hide an auto-allowed command.
                #expect(viaTerminal != .allowed,
                        "guard-rejected syntax must not auto-allow: \(probe.command)")
            }
        }
        // Guard-level hard deny stays denied for both consumers even though
        // the agent path blocks it one layer earlier than the terminal path.
        // sudo 不再是硬拒绝：语法守卫仍不当作单条简单命令，所以改为走审批（询问）。
        let wrapperProbe = snapshot.classify(command: "sudo ls")
        #expect(wrapperProbe == .confirmation)
        #expect(!TerminalGuard.inspect("sudo ls").isAllowed)
        // 硬拒绝仍然是硬拒绝。
        #expect(snapshot.classify(command: "shutdown -h now") == .denied)
    }

    @Test("path and quoting shapes cannot evade the shared hard-deny list")
    func pathAndWhitespaceVariantsCannotEvadeHardDeny() {
        let snapshot = TerminalPolicySnapshot.default
        let shapes = ["/sbin/shutdown now", "  shutdown now", "shutdown"]
        for command in shapes {
            #expect(snapshot.classify(command: command) == .denied, "\(command) must stay denied")
        }
        let agentProbe = "/sbin/shutdown"
        let inspected = TerminalGuard.inspect(agentProbe)
        if inspected.isAllowed {
            // The guard may reject the shape outright; if it lexes, the shared
            // snapshot must still deny after basename normalization.
            #expect(snapshot.classify(words: inspected.words, syntaxAllowed: true) == .denied)
        }
        for command in TerminalPolicySnapshot.productHardDeniedCommands {
            #expect(snapshot.classify(command: "/usr/sbin/\(command) --flag") == .denied)
        }
    }

    @Test("supported env and nice wrappers inherit the actual executable's rule")
    func wrappersCannotLaunderHardOrUserDeniedCommands() {
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["env", "nice", "echo", "reboot", "printf"],
            confirmationCommands: ["git"],
            userDeniedCommands: ["printf"]
        ))
        let probes: [(String, TerminalCommandDisposition)] = [
            ("env reboot Synthetic.app", .denied),
            ("/usr/bin/env -i -- reboot Synthetic.app", .denied),
            ("SAFE2_MARKER=synthetic env reboot Synthetic.app", .denied),
            ("nice -n 2 reboot Synthetic.app", .denied),
            (#"'reboot' Synthetic.app"#, .denied),
            ("env nice -- printf synthetic", .denied),
            ("env git status", .confirmation),
            ("nice echo synthetic", .allowed),
            ("env -i", .confirmation),
            (#"env echo "open""#, .confirmation),
            (#"echo "open""#, .allowed),
            (#"echo 'sudo'"#, .allowed),
        ]
        for (command, expected) in probes {
            let inspected = TerminalGuard.inspect(command)
            #expect(inspected.isAllowed, "existing simple syntax must remain supported: \(command)")
            #expect(snapshot.classify(command: command) == expected)
            #expect(snapshot.classify(words: inspected.words, syntaxAllowed: true) == expected)
        }
        // Rejected wrapper syntax remains behind the original structural
        // guard; a nested hard-deny still wins over the confirmation class.
        #expect(!TerminalGuard.inspect("env -S reboot Synthetic.app").isAllowed)
        #expect(snapshot.classify(command: "env -S reboot Synthetic.app") == .denied)
        #expect(!TerminalGuard.inspect("nice -n 2 exec halt").isAllowed)
        #expect(snapshot.classify(command: "nice -n 2 exec halt") == .denied)
    }

    @Test("security, diskutil and launchctl ask by default but dangerous subcommands stay hard-denied")
    func conditionalHardDenyKeepsSafetyFloor() {
        let snapshot = TerminalPolicySnapshot.default
        // 对齐 Claude Code：这些命令的普通用法走审批。
        for command in ["open Synthetic.app", "osascript -e 1", "screencapture x.png", "killall Finder",
                        "sudo ls", "security list-keychains", "diskutil list", "launchctl list"] {
            #expect(snapshot.classify(command: command) == .confirmation, "\(command) should ask")
        }
        // 读取钥匙串密码、抹盘、卸载系统服务仍然硬拒绝，包括写在复合命令或 sudo 之后。
        for command in ["security find-generic-password -s x -w", "security dump-keychain",
                        "diskutil eraseDisk APFS X disk2", "diskutil apfs deleteVolume disk3s1",
                        "launchctl unload /Library/LaunchDaemons/x.plist", "launchctl bootout system/x",
                        "sudo diskutil eraseDisk JHFS+ X disk2", "ls && security find-internet-password -w"] {
            #expect(snapshot.classify(command: command) == .denied, "\(command) must stay denied")
        }
    }

    @Test("an in-flight snapshot is not rewritten by a later settings edit")
    func inFlightSnapshotIsNotRewrittenByLaterSettingsEdits() throws {
        // Request boundary 1: `echo` is auto-allowed.
        let inFlight = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo"],
            confirmationCommands: [],
            userDeniedCommands: []
        ))
        // Settings edit while the first request is running: `echo` moves to
        // user-denied. The frozen snapshot of the running turn must not change.
        let edited = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: [],
            confirmationCommands: [],
            userDeniedCommands: ["echo"]
        ))
        #expect(inFlight.classify(command: "echo ok") == .allowed)
        #expect(inFlight.revision != edited.revision)
        #expect(edited.classify(command: "echo ok") == .denied)

        // The visible-terminal `TerminalPolicy` holds its snapshot by value,
        // which is the exact "已提交的终端请求继续使用各自冻结的策略快照"
        // contract surfaced in the settings UI.
        let policy = TerminalPolicy(
            scopeID: "project-1",
            allowedRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
            snapshot: inFlight
        )
        #expect(policy.snapshot.revision == inFlight.revision)
        #expect(policy.snapshot.classify(command: "echo ok") == .allowed)
    }
}
