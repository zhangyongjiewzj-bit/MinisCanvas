import Foundation
import AppKit
import Darwin
@testable import MinisCore
import Testing
@testable import MinisCanvasApp

@MainActor
private final class TerminationHarness {
    var attached = false
    var terminations = 0
    var observer: AppTerminationRequest.Action?
    var queued: [AppTerminationRequest.Action] = []
    var timeouts: [AppTerminationRequest.Action] = []
    var observationRemovals = 0
    var scheduledCancellations = 0
    var timeoutCancellations = 0

    func makeRequest() -> AppTerminationRequest {
        AppTerminationRequest(
            hasAttachedSheet: { self.attached },
            terminate: { self.terminations += 1 },
            observeSheetEnd: { action in
                self.observer = action
                return { self.observer = nil; self.observationRemovals += 1 }
            },
            scheduleResume: { action in
                self.queued.append(action)
                return { self.scheduledCancellations += 1 }
            },
            scheduleTimeout: { action in
                self.timeouts.append(action)
                return { self.timeoutCancellations += 1 }
            }
        )
    }

    func runNextTurn() {
        let actions = queued
        queued.removeAll()
        for action in actions { action() }
    }
}

@Suite("D-APP-12 user Quit waits for owned presentation dismissal")
@MainActor
struct AppTerminationRequestTests {
    @Test func ordinaryQuitKeepsCocoaTerminationBehaviorForUnownedDialog() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        request.request { false }
        #expect(harness.terminations == 1)
        #expect(harness.observer == nil)
        #expect(harness.queued.isEmpty && harness.timeouts.isEmpty)
        #expect(request.outcome == .forwarded)
    }

    @Test func settingsDismissalMustEndBeforeTerminate() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        var settingsPresented = true
        request.request { settingsPresented = false; return true }
        #expect(!settingsPresented && harness.terminations == 0)
        harness.runNextTurn()
        #expect(harness.terminations == 0, "state changed is not actual sheet ended")
        harness.attached = false
        harness.observer?()
        #expect(harness.terminations == 0, "sheet notification must defer its check")
        harness.runNextTurn()
        #expect(harness.terminations == 1)
        #expect(request.outcome == .forwarded)
        #expect(harness.observer == nil)
        #expect(harness.timeoutCancellations == 1)
    }

    @Test func repeatedQuitWhileWaitingDoesNotPrepareOrTerminateTwice() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        var preparations = 0
        request.request { preparations += 1; return true }
        request.request { preparations += 1; return true }
        #expect(preparations == 1 && harness.terminations == 0)
        let staleResume = harness.queued[0]
        let staleTimeout = harness.timeouts[0]
        harness.attached = false
        harness.observer?()
        harness.runNextTurn()
        staleResume(); staleTimeout()
        #expect(harness.terminations == 1)
    }

    @Test func timeoutRemovesObserverAndScheduledWorkWithoutForcingQuit() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        request.request { true }
        let staleResume = harness.queued[0]
        harness.timeouts[0]()
        #expect(request.outcome == .timedOut)
        #expect(harness.observer == nil && harness.observationRemovals == 1)
        #expect(harness.timeoutCancellations == 1)
        harness.attached = false
        staleResume()
        #expect(harness.terminations == 0, "expired request cannot terminate later")
        request.request { false }
        #expect(harness.terminations == 1, "a new user Quit remains possible")
    }

    @Test func previousRequestCallbacksCannotForwardOrExpireNewWaitingRequest() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        request.request { true }
        let previousResume = harness.queued[0]
        let previousTimeout = harness.timeouts[0]
        previousTimeout()
        #expect(request.outcome == .timedOut && harness.terminations == 0)
        harness.queued.removeAll()

        request.request { true }
        #expect(request.outcome == .waitingForSheet)
        #expect(harness.queued.count == 1 && harness.observer != nil)
        // The second sheet has ended, but its own deferred check has not run.
        // A stale resume without the request-ID guard would forward Quit here.
        harness.attached = false
        previousResume()
        #expect(harness.terminations == 0 && request.outcome == .waitingForSheet)
        #expect(harness.queued.count == 1 && harness.observer != nil)
        previousTimeout()
        #expect(harness.terminations == 0 && request.outcome == .waitingForSheet)
        #expect(harness.queued.count == 1 && harness.observer != nil)

        harness.observer?()
        #expect(harness.terminations == 0 && request.outcome == .waitingForSheet)
        harness.runNextTurn()
        #expect(harness.terminations == 1 && request.outcome == .forwarded)
        #expect(harness.observer == nil && harness.queued.isEmpty)
        #expect(harness.observationRemovals == 2 && harness.timeoutCancellations == 2)
    }

    @Test func sheetNotificationDuringPreparationCannotTerminateEarly() {
        let harness = TerminationHarness()
        let request = harness.makeRequest()
        request.request {
            harness.observer?()
            #expect(harness.terminations == 0)
            return true
        }
        #expect(harness.terminations == 0)
        harness.runNextTurn()
        #expect(harness.terminations == 1)
    }

    @Test func didEndSheetRechecksOnLaterTurnsWhenAttachmentClearsLate() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        request.request { true }
        harness.observer?()
        #expect(harness.terminations == 0)
        harness.runNextTurn()
        #expect(harness.terminations == 0)
        harness.attached = false
        harness.runNextTurn()
        #expect(harness.terminations == 1)
        #expect(request.outcome == .forwarded)
    }

    @Test func neverClearingSheetHasFiniteDeferredChecksAndTimeoutCleanup() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        request.request { true }
        for _ in 0..<20 { harness.runNextTurn() }
        #expect(harness.queued.isEmpty && harness.terminations == 0)
        harness.observer?()
        for _ in 0..<20 { harness.runNextTurn() }
        #expect(harness.queued.isEmpty && harness.terminations == 0)
        harness.timeouts[0]()
        #expect(request.outcome == .timedOut && harness.observer == nil)
    }

    @Test func systemTerminationClearsWaitingCallbacksWithoutWaitingForSheet() {
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        request.request { true }
        let staleResume = harness.queued[0]
        request.cancelForSystemTermination()
        #expect(harness.observer == nil && request.outcome == .forwarded)
        staleResume()
        #expect(harness.terminations == 0)
    }

    @Test func quitRejectsActualPendingWaiterBeforeSheetEnds() async throws {
        let center = ApprovalPromptCenter()
        let approval = ApprovalRequest(
            id: "app12-termination-candidate", toolName: "shell_execute",
            inputSummary: "isolated synthetic request; no executor attached",
            riskLevel: .high, requiresApproval: true
        )
        let waiter = Task { await center.present(approval) }
        defer { waiter.cancel() }
        for _ in 0..<200 where center.pendingRequest == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(center.pendingRequest == approval)
        let harness = TerminationHarness()
        harness.attached = true
        let request = harness.makeRequest()
        request.request { center.rejectForApplicationExit(); return true }
        let decision = await waiter.value
        #expect(!decision.approved)
        #expect(decision.status == .cancelled)
        #expect(decision.reason == "应用退出")
        #expect(center.pendingRequest == nil)
        #expect(harness.terminations == 0)
        harness.attached = false
        harness.observer?()
        #expect(harness.terminations == 0, "sheet notification must defer its check")
        harness.runNextTurn()
        #expect(harness.terminations == 1)
    }
}

@Suite("D-APP-12 physical tool drain before Cocoa termination")
@MainActor
struct AppToolTerminationDrainTests {
    @Test func noToolWorkKeepsSynchronousCocoaTermination() {
        let delegate = MinisCanvasAppDelegate()
        var preparations = 0
        delegate.prepareToolTermination = { preparations += 1; return nil }
        let began = ContinuousClock.now
        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        let elapsed = began.duration(to: ContinuousClock.now)
        #expect(reply == .terminateNow && preparations == 1)
        // This is a synchronous path with no cleanup Task or timer. Timing is
        // recorded only as diagnostic context, not a machine-speed threshold.
        print("APP12_NO_TOOL_TERMINATE_NOW elapsed=\(elapsed)")
    }

    @Test func actualCompletionRepliesOnceAndCancelsDeadline() {
        var deadline: AppToolTerminationDrain.Action?
        var completed: AppToolTerminationDrain.Action?
        var replies = 0
        var cancellations = 0
        let drain = AppToolTerminationDrain(scheduleDeadline: { action in
            deadline = action
            return { cancellations += 1 }
        })
        drain.request(start: { completed = $0 }, reply: { replies += 1 })
        #expect(drain.isWaiting && replies == 0)
        completed?()
        #expect(!drain.isWaiting && replies == 1 && cancellations == 1)
        completed?(); deadline?()
        #expect(replies == 1)
    }

    @Test func boundedDeadlineDoesNotWaitForUncooperativeWork() {
        var deadline: AppToolTerminationDrain.Action?
        var replies = 0
        let drain = AppToolTerminationDrain(scheduleDeadline: { action in
            deadline = action
            return {}
        })
        drain.request(start: { _ in }, reply: { replies += 1 })
        #expect(replies == 0 && drain.isWaiting)
        deadline?()
        #expect(replies == 1 && !drain.isWaiting)
    }

    @Test func repeatedQuitDoesNotStartAnotherCleanup() {
        var starts = 0
        let drain = AppToolTerminationDrain(scheduleDeadline: { _ in {} })
        drain.request(start: { _ in starts += 1 }, reply: {})
        drain.request(start: { _ in starts += 1 }, reply: {})
        #expect(starts == 1 && drain.isWaiting)
    }

    @Test func previousCompletionCannotReplyToAnotherRequest() {
        var deadlines: [AppToolTerminationDrain.Action] = []
        var completions: [AppToolTerminationDrain.Action] = []
        var replies = 0
        let drain = AppToolTerminationDrain(scheduleDeadline: { action in
            deadlines.append(action)
            return {}
        })
        drain.request(start: { completions.append($0) }, reply: { replies += 1 })
        deadlines[0]()
        drain.request(start: { completions.append($0) }, reply: { replies += 1 })
        completions[0](); deadlines[0]()
        #expect(replies == 1 && drain.isWaiting)
        completions[1]()
        #expect(replies == 2 && !drain.isWaiting)
    }
}

@Suite("B0502 retired production executor is joined at application exit", .serialized)
@MainActor
struct RetiredProductionExecutorExitTests {
    private struct Ready: Decodable {
        let pid: Int32
        let group: Int32
        let uid: UInt32
    }

    private struct LivenessObservationFailure: Error {
        let target: Int32
        let errnoValue: Int32
    }

    private func exists(_ pidOrGroup: Int32) throws -> Bool {
        let result = Darwin.kill(pidOrGroup, 0)
        let observedError = errno
        if result == 0 { return true }
        if observedError == EPERM { return true }
        if observedError == ESRCH { return false }
        // An unclassified observation is never evidence of physical absence.
        throw LivenessObservationFailure(target: pidOrGroup, errnoValue: observedError)
    }

    private func startOwnedShell(_ executor: BuiltinToolExecutor) async -> Task<String, Error> {
        let ownership = await ToolExecutionOwnershipRegistry.shared.ownership(for: executor)
        // This capture is the in-flight operation's production ownership, not
        // a separate test-side lifetime holder. The helper returns immediately.
        return Task {
            try await ownership.perform {
                try await executor.execute(name: "shell_execute", input: [
                    "command": "/usr/bin/python3 retired_worker.py", "timeout": 10
                ])
            }
        }
    }

    @Test func reinstallationKeepsOldShellOwnedUntilExitDrainPhysicallyReapsGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app12-retired-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let worker = """
        import json, os, signal, time
        def on_term(signum, frame):
            with open('term-observed.json', 'w') as f:
                json.dump({'signal': signum, 'pid': os.getpid()}, f)
                f.flush()
                os.fsync(f.fileno())
            # Deliberately ignore TERM so the existing KILL/reap path is needed.
        signal.signal(signal.SIGTERM, on_term)
        with open('ready.partial', 'w') as f:
            json.dump({'pid': os.getpid(), 'group': os.getpgrp(), 'uid': os.geteuid()}, f)
        os.replace('ready.partial', 'ready.json')
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            time.sleep(0.01)
        """
        try Data(worker.utf8).write(to: root.appendingPathComponent("retired_worker.py"))
        let bridge = BridgeStore(sessionStore: SessionStore(directory: sessions),
            canvasRuntimeState: .disabled, canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [], sessionDirectory: sessions, mcpManager: manager,
            skillStore: skills, externalRunners: [:], externalNetworkAllowed: false).value
        var old = bridge.productionBuiltinToolExecutor
        weak let retired = old
        old?.terminalPolicySnapshot = .default
        // Use the same concrete-owner registry that production AgentLoop uses,
        // not a second task/process manager or a manually assigned PID owner.
        let work = await startOwnedShell(try #require(old))
        do {
            let readyPath = root.appendingPathComponent("ready.json")
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: readyPath.path),
                  ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FileManager.default.fileExists(atPath: readyPath.path),
                         "real old worker must install handler and atomically publish ready")
            let ready = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: readyPath))
            try #require(ready.pid > 1 && ready.group > 1 && ready.uid == geteuid())
            let workerWasLive = try exists(ready.pid)
            let groupWasLive = try exists(-ready.group)
            try #require(ready.group != getpgrp() && workerWasLive && groupWasLive)
            await bridge.attachProductionServices(fileAccessAllowedRoot: root,
                fileAccessDeniedRoots: [], sessionDirectory: sessions, mcpManager: manager,
                skillStore: skills, externalRunners: [:], externalNetworkAllowed: false).value
            let current = try #require(bridge.productionBuiltinToolExecutor)
            try #require(current !== old, "must actually rebuild the production executor")
            // Release the caller's last explicit strong old-instance reference.
            // Only its real in-flight operation may keep this retired owner alive.
            old = nil
            try #require(retired != nil && retired?.hasPendingOwnedToolOperations == true &&
                         !current.hasPendingOwnedToolOperations,
                         "weak registry must find the in-flight old owner while current is idle")
            let began = ContinuousClock.now
            let drain = try #require(bridge.prepareProductionToolsForApplicationExit(),
                                     "exit must discover the old live physical tail even with current idle")
            await drain.value
            do {
                _ = try await work.value
                Issue.record("exit cancellation cannot return successful shell output")
            } catch is CancellationError {
                // Actual original ownership task has joined the production cleanup.
            }
            #expect(began.duration(to: ContinuousClock.now) <= .seconds(3))
            let workerStillExists = try exists(ready.pid)
            let groupStillExists = try exists(-ready.group)
            #expect(!workerStillExists, "retired concrete owner's worker must actually be gone")
            #expect(!groupStillExists, "retired owner's private process group must be zero")
            let marker = root.appendingPathComponent("term-observed.json")
            #expect(FileManager.default.fileExists(atPath: marker.path), "keep real TERM-before-KILL assertion")
            if FileManager.default.fileExists(atPath: marker.path) {
                let actual = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Int])
                #expect(actual["signal"] == Int(SIGTERM) && actual["pid"] == Int(ready.pid))
            }
            #expect(retired?.hasPendingOwnedToolOperations != true && !current.hasPendingOwnedToolOperations)
            let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while retired != nil, ContinuousClock.now < releaseDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(retired == nil,
                    "a drained retired executor must be releasable, not permanently retained by registry or tail")
            #expect(bridge.prepareProductionToolsForApplicationExit() == nil,
                    "drained retired generation must not delay the next idle exit")
        } catch {
            // A setup/assertion failure still joins this exact fixture's work;
            // cleanup cannot turn a failed test into a passing result.
            work.cancel()
            _ = try? await work.value
            throw error
        }
    }
}
