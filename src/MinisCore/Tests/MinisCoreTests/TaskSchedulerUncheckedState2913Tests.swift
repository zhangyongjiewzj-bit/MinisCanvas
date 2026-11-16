import Foundation
import Testing
@testable import MinisCore

private final class SchedulerThreads2913: @unchecked Sendable {
    private let condition = NSCondition()
    private var ready = 0
    private var unexpected = [0, 0]
    private var dispatched = 0

    func startTogether() {
        condition.lock()
        ready += 1
        if ready == 2 { condition.broadcast() }
        while ready < 2 { condition.wait() }
        condition.unlock()
    }

    func recordUnexpected(_ count: Int, slot: Int) {
        condition.lock()
        unexpected[slot] = count
        condition.unlock()
    }

    func recordAction() {
        condition.lock()
        dispatched += 1
        condition.unlock()
    }

    func snapshot() -> (unexpected: Int, dispatched: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (unexpected.reduce(0, +), dispatched)
    }
}

@Suite("D-CONC2 actual scheduler dictionary ownership")
struct TaskSchedulerUncheckedState2913Tests {
    // This invokes the original public scheduler, not an imitation gate.
    // The two threads overlap only actual registration and failed admission
    // lookup. On an instrumented run TSan is the race oracle; a normal green
    // run proves these false/no-effect predicates, not absence of data races.
    @Test func concurrentRegistrationAndMissingAdmissionPreserveOwnedState() {
        let scheduler = TaskScheduler()
        defer { scheduler.stopAll() }
        let threads = SchedulerThreads2913()
        let owned = BackgroundTask(
            id: "TASK2913-owned-disabled",
            title: "隔离注册",
            intervalSeconds: 3600,
            isEnabled: false
        ) {
            threads.recordAction()
        }
        #expect(scheduler.register(owned) == false)

        let completed = DispatchGroup()
        // A blocking start barrier needs two owned threads; GCD iteration
        // scheduling is not used as an implicit liveness prerequisite.
        let workers = (0..<2).map { slot in
            completed.enter()
            return Thread {
                defer { completed.leave() }
                threads.startTogether()
                var unexpected = 0
                for _ in 0..<2048 {
                    if slot == 0 {
                        if scheduler.register(owned) { unexpected += 1 }
                    } else {
                        if scheduler.enable(id: "TASK2913-missing") { unexpected += 1 }
                        if scheduler.disable(id: "TASK2913-missing") { unexpected += 1 }
                    }
                }
                threads.recordUnexpected(unexpected, slot: slot)
            }
        }
        workers.forEach { $0.start() }
        completed.wait()

        let outcome = threads.snapshot()
        #expect(outcome.unexpected == 0)
        #expect(outcome.dispatched == 0)
        #expect(scheduler.task(id: owned.id)?.generation == owned.generation)
        #expect(scheduler.task(id: owned.id)?.isEnabled == false)
        #expect(scheduler.task(id: "TASK2913-missing") == nil)
        #expect(scheduler.executionRecords().isEmpty)
    }
}
