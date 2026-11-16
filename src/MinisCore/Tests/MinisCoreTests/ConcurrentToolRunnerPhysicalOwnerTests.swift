import Foundation
import Testing
@testable import MinisCore

private final class PhysicalOwnerProbeExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var entered: [String] = []
    private var active = 0
    private var maximumActive = 0

    func execute(name: String, input: [String: Any]) async throws -> String {
        if name == "first" {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    entered.append(name)
                    active += 1
                    maximumActive = max(maximumActive, active)
                    firstContinuation = continuation
                }
            }
        } else {
            lock.withLock {
                entered.append(name)
                active += 1
                maximumActive = max(maximumActive, active)
            }
        }
        lock.withLock { active -= 1 }
        return "completed:\(name)"
    }

    func releaseFirst() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let value = firstContinuation
            firstContinuation = nil
            return value
        }
        continuation?.resume()
    }

    var entries: [String] { lock.withLock { entered } }
    var peak: Int { lock.withLock { maximumActive } }
}

@Suite("D-CONC2 canonical physical owner")
struct ConcurrentToolRunnerPhysicalOwnerTests {
    private func receipt(for name: String) -> ToolExecutionReceipt {
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "physical-owner-session", turnID: 1,
                messageID: "physical-owner-message"
            ),
            operationID: "physical-owner-operation", attempt: 1
        )
        return ToolExecutionReceipt(
            toolCallID: "physical-owner-\(name)", receiptID: "physical-owner-receipt-\(name)",
            toolName: name, attemptID: "physical-owner-attempt",
            attemptNumber: 1, executionIdentity: identity
        )
    }

    @Test("two physical calls from one canonical execution retain the configured limit of two")
    func oneExecutionCanUseTwoPermits() async {
        let runner = ConcurrentToolRunner(maxConcurrent: 2)
        let executor = PhysicalOwnerProbeExecutor()
        let firstReceipt = receipt(for: "first")
        let secondReceipt = receipt(for: "second")
        let first = Task {
            await ToolExecutionReceiptContext.$current.withValue(firstReceipt) {
                await runner.run([ToolInvocation(id: "first", name: "first")], executor: executor)
            }
        }
        defer { executor.releaseFirst(); first.cancel() }

        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(5))
        while executor.entries.isEmpty && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(executor.entries == ["first"])
        guard executor.entries == ["first"] else { return }

        let second = Task {
            await ToolExecutionReceiptContext.$current.withValue(secondReceipt) {
                await runner.run([ToolInvocation(id: "second", name: "second")], executor: executor)
            }
        }
        defer { second.cancel() }
        deadline = clock.now.advanced(by: .seconds(5))
        while executor.entries.count < 2 && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let entriesBeforeRelease = executor.entries
        let peakBeforeRelease = executor.peak
        executor.releaseFirst()
        let firstResults = await first.value
        let secondResults = await second.value

        #expect(entriesBeforeRelease == ["first", "second"])
        #expect(peakBeforeRelease == 2)
        #expect(firstResults.first?.output == "completed:first")
        #expect(secondResults.first?.output == "completed:second")
    }

    @Test("a cancelled legacy waiter cannot enter after the canonical effect exits")
    func missingIdentityCannotBypassOrDispatchLate() async {
        let runner = ConcurrentToolRunner(maxConcurrent: 2)
        let executor = PhysicalOwnerProbeExecutor()
        let receipt = receipt(for: "first")
        let first = Task {
            await ToolExecutionReceiptContext.$current.withValue(receipt) {
                await runner.run([ToolInvocation(id: "first", name: "first")], executor: executor)
            }
        }
        defer { executor.releaseFirst(); first.cancel() }

        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(5))
        while executor.entries.isEmpty && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(executor.entries == ["first"])
        guard executor.entries == ["first"] else { return }

        let legacy = Task {
            await runner.run([ToolInvocation(id: "legacy", name: "legacy")], executor: executor)
        }
        deadline = clock.now.advanced(by: .seconds(5))
        while await runner.queuedInvocationCount == 0 && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await runner.queuedInvocationCount == 1)
        #expect(executor.entries == ["first"])
        legacy.cancel()
        let cancelled = await legacy.value
        #expect(cancelled.first?.terminalStatus == .cancelled)

        executor.releaseFirst()
        _ = await first.value
        // This positive call must wait for the detached physical release and
        // therefore also exposes a cancelled waiter dispatched after release.
        let after = await runner.run(
            [ToolInvocation(id: "after", name: "after")], executor: executor
        )
        #expect(after.first?.output == "completed:after")
        #expect(await runner.queuedInvocationCount == 0)
        #expect(executor.entries == ["first", "after"])
        #expect(executor.peak == 1)
    }
}
