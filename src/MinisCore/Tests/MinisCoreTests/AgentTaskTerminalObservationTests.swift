import Foundation
import Testing
@testable import MinisCore

@Suite struct AgentTaskTerminalObservationTests {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [AgentTaskTerminalObservation] = []
        func append(_ value: AgentTaskTerminalObservation) {
            lock.lock(); defer { lock.unlock() }; observations.append(value)
        }
        var values: [AgentTaskTerminalObservation] {
            lock.lock(); defer { lock.unlock() }; return observations
        }
    }

    private func fixture(hasSource: Bool = true) throws -> (AgentTaskStore, URL, AgentTaskSnapshot, AgentRunSnapshot) {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("goal18-terminal-observer-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try #require(root.path.hasPrefix(profile.rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        let parent = ParentRuntimeIdentity(sessionID: "actual-source-session", conversationID: "actual-source-session",
            turnID: "turn-handle:1", taskID: "not-a-session-id", actorID: "synthetic-owner")
        let task = try store.enqueue(taskID: "child", parentID: parent.taskID, providerID: nil, modelID: nil,
            parentRuntimeIdentity: hasSource ? parent : nil)
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "terminal-run")
        return (store, url, task, run)
    }

    @Test func finishObservesCommittedReceiptOutsideLockAndNeverReplays() throws {
        let (store, url, task, run) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capture = Capture()
        store.setTerminalObserver { observation in
            // Both reads reenter the instance or durable store: callback must
            // run after the instance and persistence locks have been released.
            #expect(store.receipt(runID: run.runID)?.outcome == .succeeded)
            #expect((try? AgentTaskStore(persistenceURL: url).receipt(runID: run.runID)) != nil)
            capture.append(observation)
        }
        let receipt = try store.finish(runID: run.runID, outcome: .succeeded)
        #expect(try store.finish(runID: run.runID, outcome: .failed(reason: "late")) == receipt)
        #expect(capture.values.count == 1)
        let event = try #require(capture.values.first)
        #expect(event.taskID == task.taskID && event.parentID == task.parentID)
        #expect(event.runID == run.runID && event.attemptID == store.attempts(runID: run.runID).first?.attemptID)
        #expect(event.sourceSessionID == "actual-source-session")
        #expect(event.sourceSessionID != task.parentID && event.outcome == .completed)
        let reopened = try AgentTaskStore(persistenceURL: url)
        reopened.setTerminalObserver { capture.append($0) }
        _ = try reopened.finish(runID: run.runID, outcome: .succeeded)
        #expect(capture.values.count == 1)
    }

    @Test func childSettlementFailureHasNoObservationAndExactReplayIsSilent() throws {
        let (store, url, task, run) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capture = Capture()
        let faulted = try AgentTaskStore(persistenceURL: url, persistenceFault: .diskFull)
        faulted.setTerminalObserver { capture.append($0) }
        let attempt = try #require(store.attempts(runID: run.runID).first)
        let envelope = ChildResultEnvelope(taskID: task.taskID, runID: run.runID, attemptID: attempt.attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID, childExecutionID: "owned-execution",
            outcome: .failed(reason: "synthetic-private-output"), resultDigest: "sha256:owned-result", evidenceRefs: [])
        #expect(throws: AgentTaskStoreError.persistenceFailed) { _ = try faulted.settleChildResult(envelope) }
        #expect(capture.values.isEmpty)
        #expect(faulted.receipt(runID: run.runID) == nil)
        store.setTerminalObserver { observation in
            #expect(store.receipt(runID: run.runID)?.childResultEnvelope == envelope)
            capture.append(observation)
        }
        let receipt = try store.settleChildResult(envelope)
        #expect(try store.settleChildResult(envelope) == receipt)
        #expect(capture.values.count == 1)
        #expect(capture.values.first?.outcome == .failed)
        #expect(capture.values.first?.sourceSessionID == "actual-source-session")
    }
    @Test func cancelledReceiptNeverObservesALateSuccessOrStaleAttempt() throws {
        let (store, url, task, run) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capture = Capture()
        store.setTerminalObserver { capture.append($0) }
        let attempt = try #require(store.attempts(runID: run.runID).first)
        let stale = ChildResultEnvelope(taskID: task.taskID, runID: run.runID, attemptID: "stale-attempt",
            parentContextSnapshotID: task.parentContextSnapshotID, childExecutionID: "owned-execution",
            outcome: .succeeded, resultDigest: "sha256:stale-result", evidenceRefs: [])
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) { _ = try store.settleChildResult(stale) }
        #expect(capture.values.isEmpty)
        let cancelled = try store.finish(runID: run.runID, outcome: .cancelled)
        let late = ChildResultEnvelope(taskID: task.taskID, runID: run.runID, attemptID: attempt.attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID, childExecutionID: "owned-execution",
            outcome: .succeeded, resultDigest: "sha256:late-result", evidenceRefs: [])
        #expect(throws: AgentTaskStoreError.childResultCancelled) { _ = try store.settleChildResult(late) }
        #expect(store.receipt(runID: run.runID) == cancelled)
        #expect(capture.values.count == 1 && capture.values.first?.outcome == .cancelled)
    }

    @Test func absentCanonicalSourceNeverFallsBackToParentID() throws {
        let (store, url, task, run) = try fixture(hasSource: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(task.sourceSessionID == nil && !task.parentID.isEmpty)
        let capture = Capture()
        store.setTerminalObserver { capture.append($0) }
        _ = try store.finish(runID: run.runID, outcome: .succeeded)
        #expect(store.receipt(runID: run.runID)?.outcome == .succeeded)
        #expect(capture.values.isEmpty)
    }

}
