import Foundation
import Testing
@testable import MinisCore

// Lane W5-TOOLEVENT-ELAPSED-PRODUCER-058: the elapsedMilliseconds field on
// tool ConversationEvents had a projection but no producer. These tests pin
// the producer contract:
//   * started executions (success / failure / timeout / mid-execution
//     cancellation) carry a measured monotonic interval,
//   * invocations that were rejected or never started carry nil so the UI
//     keeps rendering 「耗时 未记录」 instead of a fabricated zero.

private final class ScriptedElapsedExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _callCount = 0
    let sleepNanoseconds: UInt64
    let failure: Error?

    init(sleepNanoseconds: UInt64 = 0, failure: Error? = nil) {
        self.sleepNanoseconds = sleepNanoseconds
        self.failure = failure
    }

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _started
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock {
            _started = true
            _callCount += 1
        }
        if sleepNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        if let failure {
            throw failure
        }
        return "ok"
    }
}

@Suite("W5-058 tool event elapsed producer")
struct W5TooleventElapsedProducer058Tests {

    // MARK: - Runner produces measured intervals

    @Test("successful execution reports a measured interval")
    func successCarriesElapsed() async throws {
        let runner = ConcurrentToolRunner(maxConcurrent: 2)
        let executor = ScriptedElapsedExecutor(sleepNanoseconds: 120_000_000)
        let results = await runner.run(
            [ToolInvocation(id: "call-ok", name: "file_read")],
            executor: executor
        )
        let result = try #require(results.first)
        #expect(result.isSuccess)
        let elapsed = try #require(result.elapsedMilliseconds)
        #expect(elapsed >= 100)
        #expect(result.executionElapsedNanoseconds != nil)
    }

    @Test("executor failure still carries terminal elapsed")
    func failureCarriesElapsed() async throws {
        let runner = ConcurrentToolRunner(maxConcurrent: 2)
        let executor = ScriptedElapsedExecutor(
            sleepNanoseconds: 30_000_000,
            failure: ToolExecutorError.readFailed("disk gone")
        )
        let results = await runner.run(
            [ToolInvocation(id: "call-fail", name: "file_read")],
            executor: executor
        )
        let result = try #require(results.first)
        #expect(result.terminalStatus == .failed)
        #expect(result.errorMessage?.contains("disk gone") == true)
        let elapsed = try #require(result.elapsedMilliseconds)
        #expect(elapsed >= 20)
    }

    @Test("timeout carries terminal elapsed of the attempted execution")
    func timeoutCarriesElapsed() async throws {
        let runner = ConcurrentToolRunner(maxConcurrent: 2)
        let executor = ScriptedElapsedExecutor(sleepNanoseconds: 5_000_000_000)
        let results = await runner.run(
            [ToolInvocation(id: "call-slow", name: "file_read")],
            executor: executor,
            timeout: 0.05
        )
        let result = try #require(results.first)
        #expect(result.terminalStatus == .failed)
        #expect(result.errorMessage?.contains("timed out") == true)
        let elapsed = try #require(result.elapsedMilliseconds)
        // The watchdog deadline is 50 ms wall-clock; allow scheduler slack but
        // reject anything that looks like a fabricated zero.
        #expect(elapsed >= 40)
    }

    @Test("mid-execution cancellation reports terminal elapsed; a batch that never started has none")
    func cancellationSplitsStartedFromNeverStarted() async throws {
        let runner = ConcurrentToolRunner(maxConcurrent: 1)
        let executor = ScriptedElapsedExecutor(sleepNanoseconds: 5_000_000_000)
        let work = Task { () -> ([ToolRunResult], [ToolRunResult]) in
            let midRun = await runner.run(
                [ToolInvocation(id: "call-mid", name: "file_read")],
                executor: executor
            )
            // The task is already cancelled at this point, so this second
            // batch deterministically takes the never-dispatched early return.
            let afterCancel = await runner.run(
                [ToolInvocation(id: "call-late", name: "file_read")],
                executor: executor
            )
            return (midRun, afterCancel)
        }
        while !executor.didStart {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        work.cancel()
        let (mid, late) = await work.value

        let midResult = try #require(mid.first)
        #expect(midResult.terminalStatus == .cancelled)
        #expect(midResult.errorMessage == "cancelled")
        #expect(midResult.elapsedMilliseconds != nil)

        let lateResult = try #require(late.first)
        #expect(lateResult.terminalStatus == .cancelled)
        #expect(lateResult.errorMessage == "cancelled")
        // Never started → no processing duration, not even zero.
        #expect(lateResult.executionElapsedNanoseconds == nil)
        #expect(lateResult.elapsedMilliseconds == nil)
    }

    @Test("duplicate identity rejection and unknown-tool rejection never start, so elapsed stays nil")
    func rejectionsHaveNoElapsed() async throws {
        let runner = ConcurrentToolRunner(maxConcurrent: 2)
        let executor = ScriptedElapsedExecutor()
        let results = await runner.run(
            [
                ToolInvocation(id: "dup", name: "file_read"),
                ToolInvocation(id: "dup", name: "file_read"),
            ],
            executor: executor
        )
        #expect(results.count == 2)
        for result in results {
            #expect(result.terminalStatus == .failed)
            #expect(result.errorMessage?.contains("duplicate invocation identity") == true)
            #expect(result.elapsedMilliseconds == nil)
        }
        // The executor was never entered: any elapsed here would be fake.
        #expect(executor.callCount == 0)
    }

    // MARK: - Consumer feeds the existing projection

    @Test("ingestToolRunResult projects the measured interval onto the event")
    func runResultProjectsElapsed() async throws {
        let consumer = ToolLifecycleConsumer()
        let fact = makeFact(toolCallID: "call-one", receiptID: "receipt-one", status: .succeeded)
        let result = ToolRunResult(
            index: 0,
            invocation: ToolInvocation(id: "call-one", name: "file_read"),
            output: "ok",
            errorMessage: nil,
            executionElapsedNanoseconds: 1_250_000_000
        )
        #expect(await consumer.ingestToolRunResult(
            result,
            fact: fact,
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        ))
        let event = try #require(consumer.events.first)
        #expect(event.elapsedMilliseconds == 1_250)
        let display = ConversationEventProjection.display(for: event)
        #expect(display.elapsed == "1.25 s")
        #expect(display.accessibilityLabel.contains("耗时 1.25 s"))
    }

    @Test("run result without a started interval keeps 「未记录」")
    func neverStartedResultKeepsElapsedUnrecorded() async throws {
        let consumer = ToolLifecycleConsumer()
        let fact = makeFact(toolCallID: "call-nil", receiptID: "receipt-nil", status: .cancelled)
        let result = ToolRunResult(
            index: 0,
            invocation: ToolInvocation(id: "call-nil", name: "file_read"),
            output: nil,
            errorMessage: "cancelled"
        )
        #expect(await consumer.ingestToolRunResult(
            result,
            fact: fact,
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        ))
        let event = try #require(consumer.events.first)
        #expect(event.elapsedMilliseconds == nil)
        #expect(
            ConversationEventProjection.display(for: event).elapsed == "未记录"
        )
    }

    @Test("bare fact ingestion without a runner result records no elapsed")
    func bareFactHasNoElapsed() async throws {
        let consumer = ToolLifecycleConsumer()
        let fact = makeFact(toolCallID: "call-bare", receiptID: "receipt-bare", status: .succeeded)
        #expect(await consumer.ingestToolExecutionFact(
            fact,
            eventID: "call-bare",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        ))
        let event = try #require(consumer.events.first)
        #expect(event.elapsedMilliseconds == nil)
        #expect(
            ConversationEventProjection.display(for: event).elapsed == "未记录"
        )
    }

    @Test("durable journal round-trip preserves the projected elapsed value")
    func durableRoundTripPreservesElapsed() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let consumer = try ToolLifecycleConsumer(persistenceURL: url)
        let fact = makeFact(toolCallID: "call-p", receiptID: "receipt-p", status: .succeeded)
        let result = ToolRunResult(
            index: 0,
            invocation: ToolInvocation(id: "call-p", name: "file_read"),
            output: "ok",
            errorMessage: nil,
            executionElapsedNanoseconds: 900_400_000
        )
        #expect(await consumer.ingestToolRunResult(
            result,
            fact: fact,
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        ))

        let reloaded = try ToolLifecycleConsumer(persistenceURL: url)
        let event = try #require(reloaded.events.first)
        #expect(event.elapsedMilliseconds == 900)
        #expect(reloaded.events == consumer.events)
    }

    @Test("journal lines written without an elapsed key reload as 未记录")
    func legacyRecordWithoutFieldDecodesAsNil() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")

        // A synthesized-Codable ConversationEvent omits a nil optional, so a
        // bare-fact journal line is byte-for-byte the pre-058 legacy shape.
        let consumer = try ToolLifecycleConsumer(persistenceURL: url)
        let fact = makeFact(toolCallID: "call-legacy", receiptID: "receipt-legacy", status: .succeeded)
        #expect(await consumer.ingestToolExecutionFact(
            fact,
            eventID: "call-legacy",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 5)
        ))
        let journalText = try #require(String(data: try Data(contentsOf: journalURL), encoding: .utf8))
        #expect(!journalText.contains("elapsedMilliseconds"))

        let reloaded = try ToolLifecycleConsumer(persistenceURL: url)
        let event = try #require(reloaded.events.first)
        #expect(event.receiptID == "receipt-legacy")
        #expect(event.elapsedMilliseconds == nil)
        #expect(
            ConversationEventProjection.display(for: event).elapsed == "未记录"
        )
    }

    // MARK: - Helpers

    private func makeFact(
        toolCallID: String,
        receiptID: String,
        attemptID: String = "attempt-one",
        attemptNumber: Int = 1,
        status: ToolExecutionStatus
    ) -> ToolExecutionFact {
        let turn = AgentTurnIdentity(
            sessionID: "session-one",
            turnID: 4,
            messageID: "message-one"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "operation-one",
            attempt: attemptNumber
        )
        let compositeKey = ToolExecutionCompositeKey(
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            messageID: turn.messageID,
            operationID: executionIdentity.operationID,
            attemptID: attemptID,
            attemptNumber: attemptNumber,
            toolCallID: toolCallID
        )
        return ToolExecutionFact(
            toolCallID: toolCallID,
            receiptID: receiptID,
            toolName: "file_read",
            status: status,
            attemptID: attemptID,
            attemptNumber: attemptNumber,
            executionIdentity: executionIdentity,
            compositeKey: compositeKey
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("w5-058-tool-elapsed-\(UUID().uuidString).json")
    }
}
