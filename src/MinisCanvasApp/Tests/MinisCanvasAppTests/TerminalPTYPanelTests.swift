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

    @Test func missingOrBlankWorkdirStartsInHomeDirectory() {
        for workdir in [nil, "  \n"] as [String?] {
            guard case .launch(let plan) = decide(workdir: workdir) else {
                Issue.record("没有项目目录时应在家目录启动")
                return
            }
            #expect(plan.currentDirectory == NSHomeDirectory())
        }
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

    // MARK: 多终端标签

    @Test func tabListAddsSelectsNewTabAndNumbersNeverReuse() {
        var list = TerminalPTYTabList()
        #expect(list.selected == nil)
        #expect(list.add() == 1)
        #expect(list.add() == 2)
        #expect(list.selected == 2)
        list.select(1)
        #expect(list.selected == 1)
        list.select(99)
        #expect(list.selected == 1)
        list.close(2)
        #expect(list.add() == 3)
        #expect(list.tabs == [1, 3])
    }

    @Test func tabListCapsAtMaxAndFreesSlotOnClose() {
        var list = TerminalPTYTabList()
        for _ in 0..<TerminalPTYTabList.maxTabs { _ = list.add() }
        #expect(!list.canAddTab)
        #expect(list.add() == nil)
        #expect(list.tabs.count == TerminalPTYTabList.maxTabs)
        list.close(3)
        #expect(list.canAddTab)
        #expect(list.add() == TerminalPTYTabList.maxTabs + 1)
    }

    @Test func closingSelectedTabPicksRightNeighbourThenLeftThenNone() {
        var list = TerminalPTYTabList()
        for _ in 0..<4 { _ = list.add() }          // [1,2,3,4] 选中 4
        list.select(2)
        #expect(list.close(2) == 3)                // 右邻
        #expect(list.close(4) == 3)                // 关非当前：选中不变
        list.select(3)
        #expect(list.close(3) == 1)                // 无右邻选左邻
        #expect(list.close(1) == nil)              // 最后一个：不自动再开
        #expect(list.tabs.isEmpty)
        #expect(list.selected == nil)
        #expect(list.close(1) == nil)
    }

    // MARK: MC4-006/007/008/018/022

    @Test func onlySafetySwitchRetiresAllTerminals() {
        #expect(TerminalPTYBlockReason.sideEffectsDisabled.retiresAllTerminals)
        #expect(!TerminalPTYBlockReason.workingDirectoryUnavailable("/gone").retiresAllTerminals)
        #expect(!TerminalPTYBlockReason.missingWorkingDirectory.retiresAllTerminals)
    }

    @Test func unavailableDirectoryMessageNamesPathAndPromisesNoSilentFallback() {
        let message = TerminalPTYBlockReason.workingDirectoryUnavailable("/gone").message
        #expect(message.contains("/gone"))
        #expect(message.contains("不会自动改到其他目录"))
    }

    @Test func boundWorkdirIsKeptEvenIfMissingAndHomeOnlyWhenUnbound() {
        #expect(TerminalPTYPlanner.resolveWorkdir(bound: "/bound/gone", home: "/home") == "/bound/gone")
        #expect(TerminalPTYPlanner.resolveWorkdir(bound: " /bound \n", home: "/home") == "/bound")
        #expect(TerminalPTYPlanner.resolveWorkdir(bound: nil, home: "/home") == "/home")
        #expect(TerminalPTYPlanner.resolveWorkdir(bound: "  ", home: "/home") == "/home")
    }

    @Test func deletedSessionsAreSelectedForRetirementRegardlessOfPanelState() {
        let stale = TerminalPTYPlanner.sessionIDsToRetire(live: ["a", "b", "c"], keeping: ["b"])
        #expect(Set(stale) == ["a", "c"])
        #expect(TerminalPTYPlanner.sessionIDsToRetire(live: ["a"], keeping: ["a"]).isEmpty)
        #expect(TerminalPTYPlanner.sessionIDsToRetire(live: [], keeping: []).isEmpty)
    }

    @MainActor
    @Test func snapshotKeepsBoundMissingDirectoryAndPlannerBlocksIt() {
        let missing = NSTemporaryDirectory() + "mc4-008-missing-\(UUID().uuidString)"
        let chat = ChatStore()
        chat.newSession(projectID: "p", projectName: "P", workingDirectory: missing)
        let snapshot = TerminalContextSnapshot.current(from: chat)
        #expect(snapshot?.workdir == missing)
        #expect(snapshot?.workdir != NSHomeDirectory())
        #expect(decide(workdir: snapshot?.workdir, dirExists: false)
            == .blocked(.workingDirectoryUnavailable(missing)))
    }

    @MainActor
    @Test func snapshotWithoutProjectDirectoryUsesHome() {
        let chat = ChatStore()
        chat.newSession(projectID: nil, projectName: nil, workingDirectory: nil)
        #expect(TerminalContextSnapshot.current(from: chat)?.workdir == NSHomeDirectory())
    }

    @Test func closingOtherTabKeepsSelection() {
        var list = TerminalPTYTabList()
        for _ in 0..<3 { _ = list.add() }
        list.select(2)
        list.close(1)
        #expect(list.selected == 2)
        #expect(list.tabs == [2, 3])
    }
}
