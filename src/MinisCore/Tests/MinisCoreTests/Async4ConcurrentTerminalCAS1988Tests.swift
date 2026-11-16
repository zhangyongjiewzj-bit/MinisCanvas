import Foundation
import Testing
@testable import MinisCore

private final class ConcurrentTerminalResults1988: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<AgentTaskReceipt, Error>] = []

    func append(_ result: Result<AgentTaskReceipt, Error>) {
        lock.lock()
        stored.append(result)
        lock.unlock()
    }

    var values: [Result<AgentTaskReceipt, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite("ASYNC4 concurrent terminal CAS")
struct Async4ConcurrentTerminalCAS1988Tests {
    @Test("independent writers racing different terminals for one attempt persist only the winner")
    func independentStoresRaceSameAttemptTerminal() throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("async4-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("tasks.json")

        let setup = try AgentTaskStore(persistenceURL: ledgerURL)
        let task = try setup.enqueue(taskID: "async4-child", parentID: "async4-parent",
                                     providerID: "provider", modelID: "model")
        let run = try setup.startRun(taskID: task.taskID, parentID: task.parentID,
                                     runID: "async4-run")
        let attemptID = try #require(setup.canonicalAttemptID(runID: run.runID))

        // Both independent instances load the same durable running attempt
        // before either writer is allowed to enter the production settlement.
        let successWriter = try AgentTaskStore(persistenceURL: ledgerURL)
        let failureWriter = try AgentTaskStore(persistenceURL: ledgerURL)
        let success = ChildResultEnvelope(taskID: task.taskID, runID: run.runID,
            attemptID: attemptID, parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "async4-execution", outcome: .succeeded,
            resultDigest: "sha256:async4-success")
        let failure = ChildResultEnvelope(taskID: task.taskID, runID: run.runID,
            attemptID: attemptID, parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "async4-execution", outcome: .failed(reason: "synthetic failure"),
            resultDigest: "sha256:async4-failure")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let results = ConcurrentTerminalResults1988()
        for (writer, envelope) in [(successWriter, success), (failureWriter, failure)] {
            completed.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                arrived.signal()
                release.wait()
                results.append(Result { try writer.settleChildResult(envelope) })
                completed.leave()
            }
        }
        let bothEntered = arrived.wait(timeout: .now() + 10) == .success
            && arrived.wait(timeout: .now() + 10) == .success
        release.signal()
        release.signal()
        let bothCompleted = completed.wait(timeout: .now() + 10) == .success
        #expect(bothEntered, "Both production writers must reach the release barrier")
        #expect(bothCompleted, "Both production settlement calls must reach a real terminal result")
        guard bothEntered && bothCompleted else { return }

        let outcomes = results.values
        let winners = outcomes.compactMap { try? $0.get() }
        let failures = outcomes.compactMap { result -> AgentTaskStoreError? in
            guard case .failure(let error) = result else { return nil }
            return error as? AgentTaskStoreError
        }
        #expect(outcomes.count == 2, "Actual outcomes: \(outcomes)")
        #expect(winners.count == 1, "Exactly one terminal write must win: \(outcomes)")
        #expect(failures == [.staleWriter], "The other independent writer must lose the durable CAS: \(outcomes)")
        let winner = try #require(winners.first)

        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(reopened.allReceipts() == [winner])
        #expect(reopened.receipt(runID: run.runID) == winner)
        #expect(reopened.childResultEnvelope(runID: run.runID) == winner.childResultEnvelope)
        #expect(reopened.events(runID: run.runID).filter { event in
            event.kind == .completed || event.kind == .failed || event.kind == .cancelled
        }.count == 1)
        #expect(reopened.attempt(runID: run.runID, attemptID: attemptID)?.status ==
            (winner.outcome == .succeeded ? .succeeded : .failed))
    }
}
