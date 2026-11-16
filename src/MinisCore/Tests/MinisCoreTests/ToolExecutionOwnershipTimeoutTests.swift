import Foundation
import Testing
@testable import MinisCore

private final class OwnedBuiltinForwarder: BuiltinOwnerBoundToolExecutor {
    let base: BuiltinToolExecutor

    init(base: BuiltinToolExecutor) { self.base = base }
    var currentBuiltinOwner: BuiltinToolExecutor? { base }

    func execute(name: String, input: [String: Any]) async throws -> String {
        try await base.execute(name: name, input: input)
    }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard owner === base else { throw ToolExecutorError.resourceScopeInvalid }
        return try await base.execute(name: name, input: input)
    }
}

private actor StalledToolCall {
    private var release: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var logicalCallReturned = false
    private var released = false
    private var secondCallCount = 0

    func waitUntilStarted() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !didStart && !logicalCallReturned && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return didStart
    }

    func noteLogicalCallReturned() { logicalCallReturned = true }

    func first() async -> String {
        didStart = true
        if !released { await withCheckedContinuation { release = $0 } }
        return "first-finished"
    }

    func second() -> String {
        secondCallCount += 1
        return "second-finished"
    }

    func secondStarts() -> Int { secondCallCount }

    func releaseFirst() {
        released = true
        release?.resume()
        release = nil
    }
}


// Observe unstructured tasks without a task-group scope that must join a
// non-cooperative operation after its deadline. Each case releases its own gate.
private actor OwnershipTaskResult<Value: Sendable> {
    var value: Result<Value, Error>?
    func store(_ value: Result<Value, Error>) { self.value = value }
}

private func ownershipResult<Value: Sendable>(
    _ task: Task<Value, Error>, phase: String
) async -> Result<Value, Error>? {
    let box = OwnershipTaskResult<Value>()
    Task { await box.store(await task.result) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while ContinuousClock.now < deadline {
        if let result = await box.value { return result }
        try? await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    Issue.record("ownership fixture did not finish: \(phase) within 15s")
    return nil
}

@Suite("Tool execution ownership after timeout")
struct ToolExecutionOwnershipTimeoutTests {
    @Test("two decorators of one built-in executor share its physical tail")
    func differentDecoratorsSharePhysicalTail() async throws {
        let builtin = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory)
        let firstDecorator = OwnedBuiltinForwarder(base: builtin)
        let secondDecorator = OwnedBuiltinForwarder(base: builtin)
        let firstOwner = await ToolExecutionOwnershipRegistry.shared.ownership(for: firstDecorator)
        let secondOwner = await ToolExecutionOwnershipRegistry.shared.ownership(for: secondDecorator)
        #expect(firstOwner === secondOwner)

        let gate = StalledToolCall()
        defer { Task { await gate.releaseFirst() } }
        let first = Task {
            defer { Task { await gate.noteLogicalCallReturned() } }
            return try await executeToolWithTimeout(
                name: "first", timeout: 2, ownership: firstOwner
            ) { await gate.first() }
        }
        guard await gate.waitUntilStarted() else {
            first.cancel()
            Issue.record("first operation did not enter before logical completion or 15s admission deadline")
            return
        }
        guard let firstResult = await ownershipResult(first, phase: "first logical timeout") else { return }
        do {
            _ = try firstResult.get()
            Issue.record("first call did not time out")
        } catch ToolExecutorError.toolTimeout { }
        let second = Task {
            try await executeToolWithTimeout(
                name: "second", timeout: 1, ownership: secondOwner
            ) { await gate.second() }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gate.secondStarts() == 0)
        await gate.releaseFirst()
        guard let secondResult = await ownershipResult(second, phase: "second physical completion") else { return }
        #expect(try secondResult.get() == "second-finished")
    }

    @Test("physical timed-out call excludes the next call on the same owner")
    func timedOutPhysicalCallExcludesNextCall() async throws {
        let owner = ToolExecutionOwnership()
        let gate = StalledToolCall()
        defer { Task { await gate.releaseFirst() } }

        let first = Task {
            defer { Task { await gate.noteLogicalCallReturned() } }
            return try await executeToolWithTimeout(
                name: "first", timeout: 2, ownership: owner
            ) {
                await gate.first()
            }
        }
        guard await gate.waitUntilStarted() else {
            first.cancel()
            Issue.record("first operation did not enter before logical completion or 15s admission deadline")
            return
        }
        guard let firstResult = await ownershipResult(first, phase: "first logical timeout") else { return }
        do {
            _ = try firstResult.get()
            Issue.record("first call did not time out")
        } catch ToolExecutorError.toolTimeout {
            // The logical deadline has fired; the physical call is still live.
        }

        let second = Task {
            try await executeToolWithTimeout(
                name: "second", timeout: 1, ownership: owner
            ) {
                await gate.second()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gate.secondStarts() == 0)
        await gate.releaseFirst()
        guard let secondResult = await ownershipResult(second, phase: "second physical completion") else { return }
        #expect(try secondResult.get() == "second-finished")
        #expect(await gate.secondStarts() == 1)
    }

    @Test("queued call that times out never executes after the predecessor exits")
    func queuedTimedOutCallDoesNotExecuteLater() async throws {
        let owner = ToolExecutionOwnership()
        let gate = StalledToolCall()
        defer { Task { await gate.releaseFirst() } }
        let first = Task {
            defer { Task { await gate.noteLogicalCallReturned() } }
            return try await executeToolWithTimeout(
                name: "first", timeout: 2, ownership: owner
            ) {
                await gate.first()
            }
        }
        guard await gate.waitUntilStarted() else {
            first.cancel()
            Issue.record("first operation did not enter before logical completion or 15s admission deadline")
            return
        }
        guard let firstResult = await ownershipResult(first, phase: "first logical timeout") else { return }
        do {
            _ = try firstResult.get()
            Issue.record("first call did not time out")
        } catch ToolExecutorError.toolTimeout { }
        let second = Task {
            try await executeToolWithTimeout(name: "second", timeout: 0.05, ownership: owner) {
                await gate.second()
            }
        }
        guard let secondResult = await ownershipResult(second, phase: "queued logical timeout") else { return }
        do {
            _ = try secondResult.get()
            Issue.record("queued call did not time out")
        } catch ToolExecutorError.toolTimeout {
            // The queued operation must be cancelled before it can dispatch.
        }
        await gate.releaseFirst()
        let third = Task {
            try await executeToolWithTimeout(name: "third", timeout: 1, ownership: owner) {
                await gate.second()
            }
        }
        guard let thirdResult = await ownershipResult(third, phase: "third physical completion") else { return }
        #expect(try thirdResult.get() == "second-finished")
        #expect(await gate.secondStarts() == 1)
    }

    @Test("a deadline before queued operation entry never dispatches that operation")
    func earlyTimeoutBeforeEntryNeverDispatches() async throws {
        let owner = ToolExecutionOwnership()
        let gate = StalledToolCall()
        defer { Task { await gate.releaseFirst() } }
        let predecessor = Task { try await owner.perform { await gate.first() } }
        guard await gate.waitUntilStarted() else {
            predecessor.cancel()
            Issue.record("positive-control predecessor did not enter within 15s")
            return
        }
        let queued = Task {
            try await executeToolWithTimeout(name: "queued-before-entry", timeout: 0.05, ownership: owner) {
                await gate.second()
            }
        }
        guard let result = await ownershipResult(queued, phase: "early timeout positive control") else { return }
        do {
            _ = try result.get()
            Issue.record("queued operation did not time out before entry")
        } catch ToolExecutorError.toolTimeout { }
        #expect(await gate.secondStarts() == 0)
        await gate.releaseFirst()
        guard let predecessorResult = await ownershipResult(predecessor, phase: "positive-control predecessor release") else { return }
        #expect(try predecessorResult.get() == "first-finished")
        let drain = Task { try await owner.perform { "tail-drained" } }
        guard let drainResult = await ownershipResult(drain, phase: "positive-control physical tail drain") else { return }
        #expect(try drainResult.get() == "tail-drained")
        #expect(await gate.secondStarts() == 0)
    }

}
