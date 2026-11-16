import Foundation
import Testing
@testable import MinisCore

private final class CONC2Source0617CompletionOwnedExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<String, Never>] = [:]
    private var enteredNames: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var teardownClosed = false

    func execute(name: String, input: [String: Any]) async throws -> String {
        await withCheckedContinuation { continuation in
            let alreadyClosed = lock.withLock { () -> Bool in
                guard !teardownClosed else { return true }
                enteredNames.append(name)
                active += 1
                maximumActive = max(maximumActive, active)
                pending[name] = continuation
                return false
            }
            if alreadyClosed { continuation.resume(returning: "completed:\(name)") }
        }
    }

    func release(_ name: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Never>? in
            guard let value = pending.removeValue(forKey: name) else { return nil }
            active -= 1
            return value
        }
        continuation?.resume(returning: "completed:\(name)")
    }

    // Teardown only: synchronous, finite release of pending and future entries.
    // This flag is never set during the assertions or timeout/cancel experiment.
    func finishForTeardown() {
        let continuations = lock.withLock { () -> [(String, CheckedContinuation<String, Never>)] in
            teardownClosed = true
            let values = Array(pending)
            pending.removeAll()
            active -= values.count
            return values
        }
        for (name, continuation) in continuations {
            continuation.resume(returning: "completed:\(name)")
        }
    }

    var names: [String] { lock.withLock { enteredNames } }
    var activeCount: Int { lock.withLock { active } }
    var peak: Int { lock.withLock { maximumActive } }
}

private actor CONC2Source0617CompletionProbe {
    var results: [ToolRunResult]?
    func record(_ results: [ToolRunResult]) { self.results = results }
}

struct CONC2Source0617ActualCompletionTests {
    @Test(arguments: [false, true])
    func outwardTerminalDoesNotReleaseAnExecutingToolsPermit(cancel: Bool) async {
        let runner = ConcurrentToolRunner(maxConcurrent: 1)
        let executor = CONC2Source0617CompletionOwnedExecutor()
        defer { executor.finishForTeardown() }
        let firstProbe = CONC2Source0617CompletionProbe()
        let first = Task {
            let result = await runner.run(
                [ToolInvocation(id: "first-owned", name: "first")],
                executor: executor, timeout: cancel ? nil : 0.02
            )
            await firstProbe.record(result)
        }
        defer { executor.release("first"); executor.release("second"); first.cancel() }

        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(5))
        while !executor.names.contains("first"), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(executor.names == ["first"])
        guard executor.names == ["first"] else { return }
        if cancel { first.cancel() }
        deadline = clock.now.advanced(by: .seconds(5))
        while await firstProbe.results == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let outward = await firstProbe.results
        #expect(outward != nil, "Caller must terminate before the cancellation-ignoring executor is released")
        guard let outward else { return }
        #expect(outward.first?.output == nil)
        #expect(cancel ? outward.first?.terminalStatus == .cancelled : outward.first?.errorMessage?.contains("timed out") == true)
        #expect(executor.activeCount == 1)

        let secondProbe = CONC2Source0617CompletionProbe()
        let second = Task {
            let result = await runner.run(
                [ToolInvocation(id: "second-owned", name: "second")], executor: executor
            )
            await secondProbe.record(result)
        }
        defer { executor.release("second"); second.cancel() }
        deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await runner.queuedInvocationCount == 1 || executor.names.contains("second") { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        // The old run defer returns its permit at outward timeout/cancel even
        // though the first actual execute invocation is still suspended.
        #expect(await runner.queuedInvocationCount == 1)
        #expect(executor.names == ["first"], "Second actual executor entry must wait for first actual completion")
        #expect(executor.peak == 1)

        executor.release("first")
        deadline = clock.now.advanced(by: .seconds(5))
        while !executor.names.contains("second"), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(executor.names == ["first", "second"])
        executor.release("second")
        deadline = clock.now.advanced(by: .seconds(5))
        while await secondProbe.results == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await secondProbe.results?.first?.output == "completed:second")
        #expect(executor.activeCount == 0)
        #expect(executor.peak == 1)
        #expect(await firstProbe.results?.first?.output == nil, "Late completion must not replace the original terminal")
    }
}
