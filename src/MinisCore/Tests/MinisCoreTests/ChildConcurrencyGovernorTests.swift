import Foundation
import Testing
@testable import MinisCore

@Suite("Child concurrency governor (P3-CHILD-40 cross-session half)")
struct ChildConcurrencyGovernorTests {

    private actor CheckpointRecorder {
        private var values: [ChildConcurrencyCheckpoint] = []
        func append(_ value: ChildConcurrencyCheckpoint) { values.append(value) }
        func latest() -> ChildConcurrencyCheckpoint? { values.last }
    }

    private static func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    // Deterministic clock: returns a monotonically increasing value the test controls.
    private static func fixedClock(_ value: TimeInterval) -> @Sendable () -> TimeInterval {
        { value }
    }

    // MARK: - Risk advisory: recommend & explain, never silently change the value

    @Test("advisory aggregates N*per-session and flags risk without mutating the selection")
    func advisoryExplainsRiskAndLeavesUserValueUntouched() throws {
        // 3 enabled sessions, user selected the 40 ceiling => 3*40 = 120 requested.
        let selection = try ChildConcurrencySelection(
            userSelected: 40,
            recommended: 8,
            effective: 4,
            enabledSessionCount: 3
        )
        let advisory = ChildConcurrencyRiskAdvisory(
            perSessionCeiling: selection.userSelected,
            enabledSessionCount: selection.enabledSessionCount,
            globalHardCeiling: 100
        )

        #expect(advisory.globalRequestedCapacity == 120)
        #expect(advisory.exceedsGlobalHardCeiling == true)
        // The advisory is derived FROM the user value; the user value is unchanged.
        #expect(selection.userSelected == 40)
        #expect(selection.effective == 4)

        // A within-budget request is reported as safe.
        let safe = ChildConcurrencyRiskAdvisory(
            perSessionCeiling: 8,
            enabledSessionCount: 3,
            globalHardCeiling: 100
        )
        #expect(safe.globalRequestedCapacity == 24)
        #expect(safe.exceedsGlobalHardCeiling == false)
    }

    @Test("advisory built from a selection reads the user-selected value, not effective")
    func advisoryUsesUserSelectedNotEffective() throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 40,
            recommended: 40,
            effective: 4,               // runtime already degraded
            enabledSessionCount: 4      // 4 sessions
        )
        let advisory = ChildConcurrencyRiskAdvisory(
            selection: selection,
            globalHardCeiling: 50
        )
        // 4 * userSelected(40) = 160, never 4 * effective(4) = 16.
        #expect(advisory.globalRequestedCapacity == 160)
        #expect(advisory.enabledSessionCount == 4)
        #expect(advisory.exceedsGlobalHardCeiling == true)
    }

    // MARK: - Global accounting + fair queueing

    @Test("admits up to the global hard ceiling then queues further launches")
    func admitsToCeilingThenQueues() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 2),
            clock: Self.fixedClock(1000)
        )

        let a = await governor.requestLaunch(sessionID: "A")
        let b = await governor.requestLaunch(sessionID: "B")
        if case .admitted(let active, _, _) = a { #expect(active == 1) } else { Issue.record("A should be admitted"); }
        if case .admitted(let active, _, _) = b { #expect(active == 2) } else { Issue.record("B should be admitted"); }

        // Third launch must suspend behind the two running ones.
        let cTask = Task { await governor.requestLaunch(sessionID: "C") }
        try? await Task.sleep(for: .milliseconds(50))
        let midCheckpoint = await governor.checkpoint()
        #expect(midCheckpoint.globalActive == 2)
        #expect(midCheckpoint.queuedSessions == ["C"])

        // Releasing A hands the slot to C (fairness: longest waiter first).
        await governor.releaseLaunch(sessionID: "A")
        let c = await cTask.value
        if case .admitted = c { } else { Issue.record("C should be admitted after A releases") }
        let after = await governor.checkpoint()
        #expect(after.globalActive == 2)
        #expect(after.queuedSessions.isEmpty)
    }

    @Test("fair queue resumes waiters in FIFO arrival order across sessions")
    func fairQueueIsFifo() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            clock: Self.fixedClock(10)
        )
        let holder = await governor.requestLaunch(sessionID: "H")
        if case .admitted = holder { } else { Issue.record("H admitted"); }

        let first = Task { await governor.requestLaunch(sessionID: "first") }
        try? await Task.sleep(for: .milliseconds(30))
        let second = Task { await governor.requestLaunch(sessionID: "second") }
        try? await Task.sleep(for: .milliseconds(30))

        let queued = await governor.checkpoint().queuedSessions
        #expect(queued == ["first", "second"])

        // Releasing the holder's single permit hands it to the head of the fair
        // queue (`first`, by arrival order), never to `second`.
        await governor.releaseLaunch(sessionID: "H")
        let f = await first.value
        if case .admitted = f { } else { Issue.record("first admitted") }
        // The freed permit is now held by `first`. The fair queue is a hand-off
        // CHAIN (one permit moves to one waiter), not a broadcast, so a single
        // release can only ever admit one waiter; `second` legitimately stays
        // queued until `first` returns the permit. Releasing `first` passes the
        // hand-off down the chain to `second`, which is what proves FIFO order all
        // the way through.
        await governor.releaseLaunch(sessionID: "first")
        let s = await second.value
        if case .admitted = s { } else { Issue.record("second admitted") }
        // Strengthened: each waiter's grant reports the queue depth it saw, which
        // pins the FIFO order (`first` woke with `second` still behind it; `second`
        // woke last with an empty queue) and confirms the hand-off never let the
        // single-permit ceiling be exceeded.
        if case .admitted(_, let queuedBehindFirst, _) = f {
            #expect(queuedBehindFirst == 1)
        } else { Issue.record("first admitted") }
        if case .admitted(_, let queuedBehindSecond, _) = s {
            #expect(queuedBehindSecond == 0)
        } else { Issue.record("second admitted") }
        #expect(await governor.currentGlobalActive == 1)
    }

    @Test("a release by a session that holds no permit must not free another child's slot or over-grant past the ceiling")
    func spuriousReleaseDoesNotOverGrant() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            clock: Self.fixedClock(4)
        )
        let h = await governor.requestLaunch(sessionID: "H")
        if case .admitted = h { } else { Issue.record("H admitted") }
        let waiter = Task { await governor.requestLaunch(sessionID: "W") }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await governor.checkpoint().queuedSessions == ["W"])

        // A release from a session that never acquired a permit must be ignored:
        // it must not drop the global count nor hand the still-live holder's permit
        // to the queued waiter (this is the phantom-release path the guarded
        // `releaseLaunch` closes; before the guard `W` would be over-admitted and
        // `queuedSessions` would be empty here).
        await governor.releaseLaunch(sessionID: "ghost")
        let guarded = await governor.checkpoint()
        #expect(guarded.globalActive == 1)            // H still holds the only permit
        #expect(guarded.queuedSessions == ["W"])      // W is NOT admitted by a phantom release

        // Only the real holder releasing revives the permit and grants the waiter.
        await governor.releaseLaunch(sessionID: "H")
        let w = await waiter.value
        if case .admitted = w { } else { Issue.record("W admitted after the real holder releases") }
        #expect(await governor.currentGlobalActive == 1)
    }

    // MARK: - Kill Switch (stop-new-launch) and resume

    @Test("kill switch refuses new launches immediately but leaves running children")
    func killSwitchStopsNewLaunch() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 4),
            clock: Self.fixedClock(7)
        )
        let running = await governor.requestLaunch(sessionID: "R")
        if case .admitted = running { } else { Issue.record("R admitted") }

        await governor.engageKillSwitch()
        let blocked = await governor.requestLaunch(sessionID: "NEW")
        if case .blockedByKillSwitch(let active, _) = blocked {
            #expect(active == 1)   // the running child is untouched
        } else {
            Issue.record("NEW should be blocked by kill switch")
        }
        #expect(await governor.isKillSwitchEngaged)

        // Resume / continue: lifting the switch allows new launches again.
        await governor.liftKillSwitch()
        let resumed = await governor.requestLaunch(sessionID: "NEW")
        if case .admitted = resumed { } else { Issue.record("NEW admitted after lift") }
    }

    @Test("engaging kill switch drains already-queued waiters as blocked")
    func killSwitchDrainsQueue() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            clock: Self.fixedClock(3)
        )
        _ = await governor.requestLaunch(sessionID: "H")
        let waiter = Task { await governor.requestLaunch(sessionID: "Q") }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await governor.checkpoint().queuedSessions == ["Q"])

        await governor.engageKillSwitch()
        let decision = await waiter.value
        if case .blockedByKillSwitch = decision { } else { Issue.record("Q drained as blocked") }
        #expect(await governor.checkpoint().queuedSessions.isEmpty)
    }

    // MARK: - Degrade actual concurrency and restore

    @Test("degrade throttles new grants without touching running children; restore resumes")
    func degradeAndRestore() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 3),
            clock: Self.fixedClock(50)
        )
        _ = await governor.requestLaunch(sessionID: "A")
        _ = await governor.requestLaunch(sessionID: "B")

        // Degrade actual concurrency to 2: already at 2 running, so C must queue.
        await governor.degradeActualConcurrency(to: 2)
        let cTask = Task { await governor.requestLaunch(sessionID: "C") }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await governor.checkpoint().queuedSessions == ["C"])

        // Release B -> slot frees to 1 which is below degraded ceiling 2 -> C admitted.
        await governor.releaseLaunch(sessionID: "B")
        let c = await cTask.value
        if case .admitted(let active, _, _) = c {
            #expect(active == 2)   // degraded ceiling respected, never reached 3
        } else {
            Issue.record("C admitted under degraded ceiling")
        }
        let state = await governor.checkpoint()
        #expect(state.degradedCeiling == 2)

        // Restore lifts the cap again.
        await governor.restoreActualConcurrency()
        let restored = await governor.checkpoint()
        #expect(restored.degradedCeiling == nil)
    }

    // MARK: - Checkpoint / resume-continuation

    @Test("checkpoint captures policy state and a restore resumes kill switch + degrade + epoch")
    func checkpointAndRestore() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 5),
            clock: Self.fixedClock(123)
        )
        _ = await governor.requestLaunch(sessionID: "A")
        await governor.degradeActualConcurrency(to: 3)
        await governor.engageKillSwitch()

        let snapshot = await governor.checkpoint()
        #expect(snapshot.killSwitchEngaged == true)
        #expect(snapshot.degradedCeiling == 3)
        #expect(snapshot.globalActive == 1)
        #expect(snapshot.timestamp == 123)   // came from the injected clock

        // JSON round-trip proves the checkpoint is machine-readable (gate contract).
        let data = try! JSONEncoder().encode(snapshot)
        let decoded = try! JSONDecoder().decode(ChildConcurrencyCheckpoint.self, from: data)
        #expect(decoded == snapshot)

        let resumed = ChildConcurrencyGovernor.restored(
            from: decoded,
            policy: .init(globalHardCeiling: 5),
            clock: Self.fixedClock(999)
        )
        // Policy resumes: still blocked for new launches because the switch is on.
        let decision = await resumed.requestLaunch(sessionID: "Z")
        if case .blockedByKillSwitch = decision { } else { Issue.record("resume keeps kill switch engaged") }
        let cp = await resumed.checkpoint()
        #expect(cp.epoch == decoded.epoch)
        #expect(cp.degradedCeiling == 3)
        // Fresh process: no children are actually running yet.
        #expect(cp.globalActive == 0)
    }

    // MARK: - Cancellation hygiene

    @Test("abandonWaiting on a never-registered request id is a safe no-op (no double resume)")
    func abandonIsSafeNoOp() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 2),
            clock: Self.fixedClock(0)
        )
        _ = await governor.requestLaunch(sessionID: "A")
        // This request was never queued: abandoning it must not crash or resume anything.
        await governor.abandonWaiting(requestID: ChildLaunchRequestID(rawValue: "ghost"))
        // Still able to admit the second real slot.
        let b = await governor.requestLaunch(sessionID: "B")
        if case .admitted = b { } else { Issue.record("B still admitted") }
    }

    @Test("abandonWaiting releases the suspended waiter of the exact request id as cancelled")
    func abandonQueuedWaiterCancels() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            clock: Self.fixedClock(0)
        )
        _ = await governor.requestLaunch(sessionID: "H")
        let requestID = ChildLaunchRequestID(rawValue: "P-req")
        let waiter = Task { await governor.requestLaunch(sessionID: "P", requestID: requestID) }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await governor.checkpoint().queuedSessions == ["P"])

        await governor.abandonWaiting(requestID: requestID)
        let decision = await waiter.value
        #expect(decision == .cancelled)
        #expect(await governor.checkpoint().queuedSessions.isEmpty)
    }

    // Boundary for audit-027: two children of the SAME session queued at once.
    // Abandoning one request must remove exactly that waiter; the sibling's
    // queue entry survives and stays grantable. Under the old sessionID +
    // firstIndex semantics, cancelling the second request removed the FIRST
    // waiter's entry and the mis-cancelled sibling could never be granted.

    @Test("same session, two queued waiters: abandoning the second spares the first, which still gets granted")
    func abandonSecondWaiterOfSameSessionKeepsFirstGrantable() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            clock: Self.fixedClock(0)
        )
        _ = await governor.requestLaunch(sessionID: "H")   // holds the only slot
        let firstID = ChildLaunchRequestID(rawValue: "S-first")
        let secondID = ChildLaunchRequestID(rawValue: "S-second")
        let first = Task { await governor.requestLaunch(sessionID: "S", requestID: firstID) }
        try? await Task.sleep(for: .milliseconds(40))
        let second = Task { await governor.requestLaunch(sessionID: "S", requestID: secondID) }
        try? await Task.sleep(for: .milliseconds(40))
        // Both siblings are queued under the same session.
        #expect(await governor.checkpoint().queuedSessions == ["S", "S"])

        // Cancel ONLY the second request.
        await governor.abandonWaiting(requestID: secondID)
        let secondDecision = await second.value
        #expect(secondDecision == .cancelled)
        // The first waiter was NOT the one removed: still exactly one queued.
        #expect(await governor.checkpoint().queuedSessions == ["S"])

        // Releasing the holder must grant the surviving first waiter.
        await governor.releaseLaunch(sessionID: "H")
        let firstDecision = await first.value
        if case .admitted = firstDecision { } else { Issue.record("first waiter of session S must still be granted") }
    }

    @Test("same session, two queued waiters: abandoning the first leaves the second queued and grantable")
    func abandonFirstWaiterOfSameSessionKeepsSecondGrantable() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            clock: Self.fixedClock(0)
        )
        _ = await governor.requestLaunch(sessionID: "H")
        let firstID = ChildLaunchRequestID(rawValue: "T-first")
        let secondID = ChildLaunchRequestID(rawValue: "T-second")
        let first = Task { await governor.requestLaunch(sessionID: "T", requestID: firstID) }
        try? await Task.sleep(for: .milliseconds(40))
        let second = Task { await governor.requestLaunch(sessionID: "T", requestID: secondID) }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await governor.checkpoint().queuedSessions == ["T", "T"])

        // Cancel ONLY the first request: it resolves as cancelled,
        await governor.abandonWaiting(requestID: firstID)
        let firstDecision = await first.value
        #expect(firstDecision == .cancelled)
        // while the second sibling remains queued...
        #expect(await governor.checkpoint().queuedSessions == ["T"])
        // ...and is the one granted when the slot frees.
        await governor.releaseLaunch(sessionID: "H")
        let secondDecision = await second.value
        if case .admitted = secondDecision { } else { Issue.record("second waiter of session T must still be granted") }
    }

    // MARK: - Budget views

    @Test("remaining budget reflects ceiling minus active and degrade")
    func remainingBudgetTracksState() async {
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 4),
            clock: Self.fixedClock(0)
        )
        #expect(await governor.remainingBudget == 4)
        _ = await governor.requestLaunch(sessionID: "A")
        #expect(await governor.remainingBudget == 3)
        await governor.degradeActualConcurrency(to: 1)
        // degraded ceiling 1, already 1 active => no remaining budget.
        #expect(await governor.remainingBudget == 0)
        #expect(await governor.globalBudget == 4)   // hard ceiling unchanged by degrade
    }

    @Test("orchestration selection hard ceiling is wired into the governor policy default")
    func derivedPolicyUsesGlobalRequest() throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 16,
            recommended: 16,
            effective: 16,
            enabledSessionCount: 3
        )
        let policy = ChildConcurrencyGovernor.Policy.derived(from: selection)
        // 3 * 16 = 48 aggregate demand accounts as the initial budget.
        #expect(policy.globalHardCeiling == 48)
    }

    @Test("checkpoint stream reports completed queue, kill, release and recovery states")
    func checkpointStreamIsLiveAndCancellationReleasesObserver() async {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let stream = await governor.checkpointUpdates()
        let recorder = CheckpointRecorder()
        let observation = Task {
            for await value in stream { await recorder.append(value) }
        }
        #expect(await governor.checkpointObserverCount == 1)
        #expect(await Self.eventually { await recorder.latest()?.globalActive == 0 })

        _ = await governor.requestLaunch(sessionID: "holder")
        #expect(await Self.eventually { await recorder.latest()?.globalActive == 1 })
        let waiting = Task { await governor.requestLaunch(sessionID: "waiting") }
        #expect(await Self.eventually { await recorder.latest()?.queuedSessions == ["waiting"] })

        await governor.degradeActualConcurrency(to: 0)
        #expect(await Self.eventually { await recorder.latest()?.degradedCeiling == 0 })
        await governor.engageKillSwitch()
        #expect(await Self.eventually {
            let snapshot = await recorder.latest()
            return snapshot?.killSwitchEngaged == true && snapshot?.queuedSessions.isEmpty == true
        })
        if case .blockedByKillSwitch = await waiting.value { } else {
            Issue.record("queued request must be released by the kill switch")
        }
        await governor.releaseLaunch(sessionID: "holder")
        #expect(await Self.eventually { await recorder.latest()?.globalActive == 0 })
        await governor.liftKillSwitch()
        #expect(await Self.eventually { await recorder.latest()?.killSwitchEngaged == false })
        await governor.restoreActualConcurrency()
        #expect(await Self.eventually {
            let snapshot = await recorder.latest()
            return snapshot?.degradedCeiling == nil && snapshot?.globalActive == 0
        })

        observation.cancel()
        #expect(await Self.eventually { await governor.checkpointObserverCount == 0 })
    }
    @Test("a restored degraded ceiling cannot expand the new hard resource policy")
    func restoredDegradedCeilingRespectsSmallerHardPolicy874() async throws {
        let prior = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 4),
            clock: Self.fixedClock(42))
        await prior.degradeActualConcurrency(to: 3)
        let checkpoint = await prior.checkpoint()
        #expect(checkpoint.degradedCeiling == 3)
        let serialized = try JSONEncoder().encode(checkpoint)
        let restored = ChildConcurrencyGovernor.restored(
            from: try JSONDecoder().decode(ChildConcurrencyCheckpoint.self, from: serialized),
            policy: .init(globalHardCeiling: 1), clock: Self.fixedClock(99))
        #expect(await restored.globalBudget == 1)
        #expect(await restored.remainingBudget == 1)
        guard case .admitted = await restored.requestLaunch(sessionID: "874-restored-holder") else {
            Issue.record("the first valid restored permit was not granted")
            return
        }
        let requestID = ChildLaunchRequestID(rawValue: "874-restored-waiter")
        let waiter = Task { await restored.requestLaunch(sessionID: "874-restored-next", requestID: requestID) }
        for _ in 0..<100 {
            let cp = await restored.checkpoint()
            if cp.queuedSessions == ["874-restored-next"] || cp.globalActive > 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let constrained = await restored.checkpoint()
        #expect(constrained.globalActive == 1)
        #expect(constrained.queuedSessions == ["874-restored-next"])
        await restored.releaseLaunch(sessionID: "874-restored-holder")
        await restored.abandonWaiting(requestID: requestID)
        guard case .admitted = await waiter.value else {
            Issue.record("the legitimate restored holder release did not resume next")
            return
        }
        await restored.releaseLaunch(sessionID: "874-restored-next")
        let complete = await restored.checkpoint()
        #expect(complete.globalActive == 0 && complete.queuedSessions.isEmpty)
        #expect(complete.perSessionActive == ["874-restored-holder": 0, "874-restored-next": 0])
    }

    @Test("managed configuration keeps physical FIFO permits and fences every stale control")
    func managedConfigurationPreservesPhysicalOwnership906() async throws {
        let initialRevision = ChildConcurrencyGovernor.ControlRevision()
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1),
            clock: Self.fixedClock(42), managedControlRevision: initialRevision)
        let initial = await governor.checkpoint()
        await governor.degradeActualConcurrency(to: 0)
        await governor.restoreActualConcurrency()
        await governor.engageKillSwitch()
        await governor.liftKillSwitch()
        #expect(await governor.checkpoint() == initial) // binding itself fences unbound controls
        guard case .admitted = await governor.requestLaunch(sessionID: "906-old-holder") else {
            Issue.record("managed initial holder did not obtain its valid permit")
            return
        }
        let firstID = ChildLaunchRequestID(rawValue: "906-old-first")
        let cancelledID = ChildLaunchRequestID(rawValue: "906-old-cancelled")
        let first = Task { await governor.requestLaunch(sessionID: "906-old-first", requestID: firstID) }
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == ["906-old-first"] { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let cancelled = Task { await governor.requestLaunch(sessionID: "906-old-cancelled", requestID: cancelledID) }
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == ["906-old-first", "906-old-cancelled"] { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await governor.checkpoint().queuedSessions == ["906-old-first", "906-old-cancelled"])
        let reconfigured = await governor.reconfigure(policy: .init(globalHardCeiling: 2),
            replacing: initialRevision, stopNewLaunches: false)
        let currentRevision = try #require(reconfigured)
        guard case .admitted = await first.value else {
            await governor.abandonWaiting(requestID: cancelledID)
            _ = await cancelled.value
            Issue.record("oldest actual waiter was not resumed by the policy increase")
            return
        }
        let oldAndNew = await governor.checkpoint()
        #expect(oldAndNew.globalActive == 2)
        #expect(oldAndNew.perSessionActive == ["906-old-holder": 1, "906-old-first": 1])
        #expect(oldAndNew.queuedSessions == ["906-old-cancelled"])
        #expect(!(await governor.degradeActualConcurrency(to: 0, controlRevision: initialRevision)))
        #expect(!(await governor.restoreActualConcurrency(controlRevision: initialRevision)))
        #expect(!(await governor.engageKillSwitch(controlRevision: initialRevision)))
        #expect(!(await governor.liftKillSwitch(controlRevision: initialRevision)))
        #expect(await governor.reconfigure(policy: .init(globalHardCeiling: 8),
            replacing: initialRevision, stopNewLaunches: false) == nil)
        #expect(await governor.globalBudget == 2)
        #expect(await governor.checkpoint() == oldAndNew)

        let nextID = ChildLaunchRequestID(rawValue: "906-new-next")
        let next = Task { await governor.requestLaunch(sessionID: "906-new-next", requestID: nextID) }
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == ["906-old-cancelled", "906-new-next"] { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await governor.checkpoint().queuedSessions == ["906-old-cancelled", "906-new-next"])
        await governor.abandonWaiting(requestID: cancelledID)
        guard case .cancelled = await cancelled.value else { Issue.record("exact cancel did not remove its waiter"); return }
        #expect(await governor.checkpoint().queuedSessions == ["906-new-next"])
        await governor.releaseLaunch(sessionID: "906-old-holder") // never fenced by configuration revision
        guard case .admitted = await next.value else { Issue.record("real old release did not resume new FIFO request"); return }
        await governor.releaseLaunch(sessionID: "906-old-first")
        await governor.releaseLaunch(sessionID: "906-new-next")
        #expect(await governor.checkpoint().perSessionActive == [
            "906-old-holder": 0, "906-old-first": 0, "906-new-next": 0])
        #expect(await governor.currentGlobalActive == 0)

        #expect(await governor.degradeActualConcurrency(to: 0, controlRevision: currentRevision))
        #expect(await governor.remainingBudget == 0)
        #expect(await governor.restoreActualConcurrency(controlRevision: currentRevision))
        #expect(await governor.remainingBudget == 2)
        #expect(await governor.engageKillSwitch(controlRevision: currentRevision))
        guard case .blockedByKillSwitch = await governor.requestLaunch(sessionID: "906-current-stop") else {
            Issue.record("the current managed controller did not stop actual requests"); return
        }
        #expect(await governor.liftKillSwitch(controlRevision: currentRevision))
        let returned = await governor.reconfigure(policy: .init(globalHardCeiling: 1),
            replacing: currentRevision, stopNewLaunches: false)
        let returnedRevision = try #require(returned)
        #expect(returnedRevision != initialRevision && returnedRevision != currentRevision)
        let beforeABA = await governor.checkpoint()
        #expect(!(await governor.engageKillSwitch(controlRevision: initialRevision)))
        #expect(!(await governor.degradeActualConcurrency(to: 0, controlRevision: currentRevision)))
        await governor.engageKillSwitch()
        #expect(await governor.checkpoint() == beforeABA)
        #expect(await governor.globalBudget == 1)
    }

    @Test("managed initial stop rejects legacy lift and reconfiguration clamps live degradation")
    func managedStopAndSmallerPolicy906() async throws {
        let revision = ChildConcurrencyGovernor.ControlRevision()
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 4),
            clock: Self.fixedClock(42), managedControlRevision: revision, stopNewLaunches: true)
        await governor.liftKillSwitch()
        guard case .blockedByKillSwitch = await governor.requestLaunch(sessionID: "906-initial-stop") else {
            Issue.record("legacy lift bypassed managed initial stop"); return
        }
        #expect(await governor.liftKillSwitch(controlRevision: revision))
        #expect(await governor.degradeActualConcurrency(to: 3, controlRevision: revision))
        guard case .admitted = await governor.requestLaunch(sessionID: "906-live-holder") else {
            Issue.record("current revision failed to lift initial stop"); return
        }
        let changed = await governor.reconfigure(policy: .init(globalHardCeiling: 1),
            replacing: revision, stopNewLaunches: false)
        let currentRevision = try #require(changed)
        let constrained = await governor.checkpoint()
        #expect(constrained.globalActive == 1 && constrained.degradedCeiling == 1)
        #expect(constrained.perSessionActive == ["906-live-holder": 1])
        #expect(await governor.remainingBudget == 0)
        #expect(await governor.restoreActualConcurrency(controlRevision: currentRevision))
        #expect(await governor.remainingBudget == 0) // restore cannot forget the old physical holder
        await governor.releaseLaunch(sessionID: "906-live-holder")
        #expect(await governor.remainingBudget == 1)
    }

}
