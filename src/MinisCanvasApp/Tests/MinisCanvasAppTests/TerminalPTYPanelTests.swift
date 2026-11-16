import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Terminal PTY panel pure logic")
struct TerminalPTYPanelTests {
    private func decide(
        workdir: String? = "/work",
        enabled: Bool = true,
        shells: [String?] = ["/bin/zsh"],
        env: [String: String] = [:],
        dirExists: Bool = true,
        executable: Set<String> = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"]
    ) -> TerminalPTYDecision {
        TerminalPTYPlanner.decide(
            workdir: workdir,
            sideEffectsEnabled: enabled,
            shellCandidates: shells,
            baseEnvironment: env,
            directoryExists: { _ in dirExists },
            isExecutable: { executable.contains($0) }
        )
    }

    // MARK: shell 选择

    @Test func shellPrefersFirstUsableCandidate() {
        let shell = TerminalPTYPlanner.resolveShell(
            candidates: ["/opt/homebrew/bin/fish", "/bin/bash"],
            isExecutable: { _ in true })
        #expect(shell == "/opt/homebrew/bin/fish")
    }

    @Test func shellSkipsRelativeMissingAndNologinCandidates() {
        let shell = TerminalPTYPlanner.resolveShell(
            candidates: [nil, "", "zsh", "/usr/bin/false", "/usr/bin/nologin", "/missing/sh", "/bin/bash"],
            isExecutable: { $0 == "/bin/bash" || $0 == "/usr/bin/false" || $0 == "/usr/bin/nologin" })
        #expect(shell == "/bin/bash")
    }

    @Test func shellFallsBackToZsh() {
        let shell = TerminalPTYPlanner.resolveShell(candidates: [nil, "/missing"], isExecutable: { _ in false })
        #expect(shell == "/bin/zsh")
    }

    @Test func launchUsesLoginShellArgumentsAndWorkdir() {
        guard case .launch(let plan) = decide(shells: ["/bin/bash"]) else {
            Issue.record("expected launch")
            return
        }
        #expect(plan.executable == "/bin/bash")
        #expect(plan.arguments == ["-l"])
        #expect(plan.currentDirectory == "/work")
    }

    // MARK: 环境变量

    @Test func environmentInheritsUserEnvAndOverlaysTerminalVariables() {
        let env = TerminalPTYPlanner.environment(
            base: ["PATH": "/usr/bin", "HOME": "/Users/u", "TERM": "dumb", "PWD": "/stale",
                   "TERM_PROGRAM": "Other", "__CFBundleIdentifier": "x", "SHELL": "/bin/sh"],
            shell: "/bin/zsh")
        #expect(env.contains("PATH=/usr/bin"))
        #expect(env.contains("HOME=/Users/u"))
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("COLORTERM=truecolor"))
        #expect(env.contains("TERM_PROGRAM=MinisCanvas"))
        #expect(env.contains("SHELL=/bin/zsh"))
        #expect(!env.contains { $0.hasPrefix("PWD=") })
        #expect(!env.contains { $0.hasPrefix("__CFBundleIdentifier=") })
        #expect(env == env.sorted())
    }

    @Test func environmentDefaultsLangOnlyWhenNoLocale() {
        #expect(TerminalPTYPlanner.environment(base: [:], shell: "/bin/zsh").contains("LANG=en_US.UTF-8"))
        let withLang = TerminalPTYPlanner.environment(base: ["LANG": "zh_CN.UTF-8"], shell: "/bin/zsh")
        #expect(withLang.contains("LANG=zh_CN.UTF-8"))
        #expect(!withLang.contains("LANG=en_US.UTF-8"))
        let withAll = TerminalPTYPlanner.environment(base: ["LC_ALL": "C.UTF-8"], shell: "/bin/zsh")
        #expect(!withAll.contains { $0.hasPrefix("LANG=") })
    }

    // MARK: cwd 与禁用开关

    @Test func disabledSwitchBlocksBeforeAnythingElse() {
        #expect(decide(workdir: nil, enabled: false) == .blocked(.sideEffectsDisabled))
        #expect(decide(enabled: false) == .blocked(.sideEffectsDisabled))
    }

    @Test func missingOrBlankWorkdirIsBlocked() {
        #expect(decide(workdir: nil) == .blocked(.missingWorkingDirectory))
        #expect(decide(workdir: "  \n") == .blocked(.missingWorkingDirectory))
    }

    @Test func nonexistentWorkdirIsBlockedWithPath() {
        #expect(decide(workdir: "/gone", dirExists: false) == .blocked(.workingDirectoryUnavailable("/gone")))
        #expect(TerminalPTYBlockReason.workingDirectoryUnavailable("/gone").message.contains("/gone"))
    }

    @Test func workdirIsTrimmed() {
        guard case .launch(let plan) = decide(workdir: " /work \n") else {
            Issue.record("expected launch")
            return
        }
        #expect(plan.currentDirectory == "/work")
    }

    @Test func identityIgnoresTurnButTracksSessionAndWorkdir() {
        let a = TerminalPTYIdentity(sessionID: "s", workdir: "/w")
        #expect(a == TerminalPTYIdentity(sessionID: "s", workdir: "/w"))
        #expect(a != TerminalPTYIdentity(sessionID: "s2", workdir: "/w"))
        #expect(a != TerminalPTYIdentity(sessionID: "s", workdir: "/w2"))
    }

    // MARK: 尺寸

    @Test func sizeIsClampedToValidWinsize() {
        #expect(TerminalPTYSize(columns: 0, rows: -5) == TerminalPTYSize(columns: 2, rows: 1))
        #expect(TerminalPTYSize(columns: 1_000_000, rows: 80).columns == Int(UInt16.max))
        #expect(TerminalPTYSize(columns: 120, rows: 30).label == "120×30")
    }

    @Test func pixelSizeScalesAndSaturates() {
        let size = TerminalPTYSize(columns: 80, rows: 24)
        let px = size.pixelSize(cellWidth: 7, cellHeight: 14, scale: 2)
        #expect(px.width == 1120)
        #expect(px.height == 672)
        let huge = size.pixelSize(cellWidth: 1e9, cellHeight: .nan, scale: 2)
        #expect(huge.width == UInt16.max)
        #expect(huge.height == 0)
    }

    // MARK: 生命周期

    @Test func lifecycleNormalRunAndExit() {
        var lifecycle = TerminalPTYLifecycle()
        #expect(!lifecycle.isAlive)
        let started1 = lifecycle.beginStart()
        #expect(started1)
        #expect(lifecycle.phase == .starting)
        lifecycle.started()
        #expect(lifecycle.phase == .running)
        #expect(lifecycle.isAlive)
        lifecycle.processExited(code: 0)
        #expect(lifecycle.phase == .exited(code: 0))
        #expect(!lifecycle.isAlive)
    }

    @Test func duplicateStartIsRejectedWhileAlive() {
        var lifecycle = TerminalPTYLifecycle()
        let started2 = lifecycle.beginStart()
        #expect(started2)
        let started3 = lifecycle.beginStart()
        #expect(!started3)
        lifecycle.started()
        let started4 = lifecycle.beginStart()
        #expect(!started4)
        #expect(lifecycle.generation == 1)
    }

    @Test func restartAfterExitBumpsGeneration() {
        var lifecycle = TerminalPTYLifecycle()
        _ = lifecycle.beginStart()
        lifecycle.started()
        lifecycle.processExited(code: nil)
        let started5 = lifecycle.beginStart()
        #expect(started5)
        #expect(lifecycle.generation == 2)
    }

    @Test func terminateSignalsOnceAndForceKillIsGenerationGuarded() {
        var lifecycle = TerminalPTYLifecycle()
        _ = lifecycle.beginStart()
        lifecycle.started()
        let generation = lifecycle.generation
        let terminated1 = lifecycle.requestTerminate()
        #expect(terminated1)
        let terminated2 = lifecycle.requestTerminate()
        #expect(!terminated2)
        #expect(lifecycle.needsForceKill(generation: generation))
        #expect(!lifecycle.needsForceKill(generation: generation + 1))
        lifecycle.processExited(code: nil)
        #expect(!lifecycle.needsForceKill(generation: generation))
        let terminated3 = lifecycle.requestTerminate()
        #expect(!terminated3)
    }

    @Test func startFailureIsTerminalUntilRestartAndIgnoresLateExit() {
        var lifecycle = TerminalPTYLifecycle()
        _ = lifecycle.beginStart()
        lifecycle.started()
        lifecycle.startFailed("boom")
        #expect(lifecycle.phase == .failed("boom"))
        lifecycle.processExited(code: 127)
        #expect(lifecycle.phase == .failed("boom"))
        let started6 = lifecycle.beginStart()
        #expect(started6)
    }

    @Test func idleLifecycleIgnoresEventsAndTerminate() {
        var lifecycle = TerminalPTYLifecycle()
        lifecycle.started()
        lifecycle.processExited(code: 1)
        #expect(lifecycle.phase == .idle)
        let terminated4 = lifecycle.requestTerminate()
        #expect(!terminated4)
    }
}
