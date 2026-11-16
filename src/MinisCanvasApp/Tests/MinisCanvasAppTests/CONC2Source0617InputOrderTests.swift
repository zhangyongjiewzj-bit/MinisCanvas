import Foundation
import Testing
@testable import MinisCore

/// Tool executor with per-name delay and failure scripting.
private final class CONC2Source0617ScriptedToolExecutor: ToolExecutor, @unchecked Sendable {
    let delays: [String: Double]
    let failures: Set<String>
    let probe: CONC2Source0617ConcurrencyProbe?

    init(delays: [String: Double] = [:], failures: Set<String> = [], probe: CONC2Source0617ConcurrencyProbe? = nil) {
        self.delays = delays
        self.failures = failures
        self.probe = probe
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        if let probe {
            await probe.enter()
            let result: String
            do {
                result = try await perform(name: name)
            } catch {
                await probe.exit()
                throw error
            }
            await probe.exit()
            return result
        }
        return try await perform(name: name)
    }

    private func perform(name: String) async throws -> String {
        if failures.contains(name) {
            throw ToolExecutorError.unknownTool(name)
        }
        if let delay = delays[name], delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return "out-\(name)"
    }
}

/// Actor tracking the maximum number of simultaneous executions.
private actor CONC2Source0617ConcurrencyProbe {
    private var current = 0
    private(set) var maxInFlight = 0

    func enter() async {
        current += 1
        if current > maxInFlight { maxInFlight = current }
    }

    func exit() {
        current -= 1
    }
}

private func conc2Source0617Invocation(_ name: String, id: String = "") -> ToolInvocation {
    ToolInvocation(id: id.isEmpty ? "call-\(name)" : id, name: name, input: ["name": name])
}

struct CONC2Source0617InputOrderTests {
    @Test func resultsReturnedInInputOrderDespiteDifferentCompletionTimes() async {
        // Completion order will be b, d, c, a — but results must be a, b, c, d.
        let executor = CONC2Source0617ScriptedToolExecutor(delays: ["a": 0.15, "c": 0.05])
        let runner = ConcurrentToolRunner(maxConcurrent: 4)

        let results = await runner.run(
            [conc2Source0617Invocation("a"), conc2Source0617Invocation("b"), conc2Source0617Invocation("c"), conc2Source0617Invocation("d")],
            executor: executor
        )

        #expect(results.map(\.invocation.name) == ["a", "b", "c", "d"])
        #expect(results.map(\.output) == ["out-a", "out-b", "out-c", "out-d"])
        let allSucceeded = results.allSatisfy { $0.isSuccess }
        #expect(allSucceeded)
    }
}
