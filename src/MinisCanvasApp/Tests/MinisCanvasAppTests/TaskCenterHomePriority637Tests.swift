import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center bounded canonical home (637)")
@MainActor
struct TaskCenterHomePriority637Tests {
    @Test(arguments: [false, true])
    func manyCompletedTasksRemainRecentWithoutHidingCurrentWork(noCurrentWork: Bool) throws {
        let root = try ownedRoot()
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(root) }
        let file = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: file)
        let consumer = TaskCenterControlConsumer(store: store)
        // ID order deliberately opposes durable settlement order.
        let completedIDs = (0..<31).map { String(format: "completed-%02d", 30 - $0) }
        for id in completedIDs {
            try finishTask(store, id: id, source: "source637", outcome: .succeeded)
        }
        // Archiving remains its own explicit durable operation. This old task
        // is not silently archived by the recent-history presentation bound.
        _ = try consumer.applyArchive(TaskCenterArchiveRequest(
            taskID: completedIDs[0], parentID: "parent637", actorID: "owned637",
            idempotencyKey: "archive637", action: .archive
        ))
        if !noCurrentWork {
            _ = try store.enqueue(taskID: "a-queued", parentID: "parent637",
                                  providerID: "offline", modelID: "fixture",
                                  parentContextSnapshotID: "source637")
            _ = try store.enqueue(taskID: "b-running", parentID: "parent637",
                                  providerID: "offline", modelID: "fixture",
                                  parentContextSnapshotID: "source637")
            _ = try store.startRun(taskID: "b-running", parentID: "parent637", runID: "run-b-running")
            _ = try store.enqueue(taskID: "z-approval", parentID: "parent637",
                                  providerID: "offline", modelID: "fixture",
                                  parentContextSnapshotID: "source637")
            let waiting = try store.startRun(taskID: "z-approval", parentID: "parent637", runID: "run-z-approval")
            _ = try store.appendEvent(runID: waiting.runID, kind: .approvalRequired, detail: "synthetic")
            try finishTask(store, id: "c-failed", source: "source637", outcome: .failed(reason: "synthetic"))
        }
        let bytesBefore = try Data(contentsOf: file)
        let snapshotsBefore = store.taskCenterSnapshots(includeArchived: true)
        let receiptsBefore = store.allReceipts()
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let sections = consumer.homeReceiptSections(TaskCenterReceiptFilter(), now: now)
        #expect(sections.recentHistory.map(\.taskID) == Array(completedIDs.reversed().prefix(20)))
        #expect(sections.recentHistory.count == TaskCenterControlConsumer.defaultRecentHistoryLimit)
        #expect(sections.recentHistory.allSatisfy { $0.lifecycleState == .completed && !$0.isArchived })
        if noCurrentWork {
            #expect(sections.current.isEmpty)
            // An empty current section never promotes the completed rows into it.
            #expect(!sections.recentHistory.isEmpty)
        } else {
            #expect(sections.current.map(\.taskID) == ["z-approval", "c-failed", "b-running", "a-queued"])
            #expect(sections.current.map(\.lifecycleState) == [.approvalRequired, .failed, .running, .queued])
        }
        #expect(Set(sections.current.map(\.stableID)).isDisjoint(with: sections.recentHistory.map(\.stableID)))
        let allRows = consumer.receiptRows(now: now, includeArchived: true)
        for row in sections.current + sections.recentHistory {
            #expect(allRows.first { $0.stableID == row.stableID } == row)
        }
        // The actual explicit Completed, Source and Archive consumers retain
        // all matches, including the older rows outside the default home bound.
        let completeFilter = TaskCenterReceiptFilter(status: .completed)
        #expect(consumer.filteredReceiptRows(completeFilter, now: now).count == 30)
        #expect(consumer.homeReceiptSections(completeFilter, now: now).recentHistory.count == 30)
        let sourceFilter = TaskCenterReceiptFilter(sourceSessionID: "source637")
        #expect(consumer.homeReceiptSections(sourceFilter, now: now).recentHistory.count == 30)
        let archiveFilter = TaskCenterReceiptFilter(status: .completed, sourceSessionID: "source637", includeArchived: true)
        let fullHistory = consumer.filteredReceiptRows(archiveFilter, now: now)
        #expect(Set(fullHistory.map(\.taskID)) == Set(completedIDs))
        #expect(fullHistory.filter(\.isArchived).map(\.taskID) == [completedIDs[0]])
        let reopened = try AgentTaskStore(persistenceURL: file)
        let recovered = TaskCenterControlConsumer(store: reopened)
        let reopenedSections = recovered.homeReceiptSections(TaskCenterReceiptFilter(), now: now)
        #expect(reopenedSections.current.map(\.stableID) == sections.current.map(\.stableID))
        #expect(reopenedSections.current.map(\.observationIdentity) == sections.current.map(\.observationIdentity))
        #expect(reopenedSections.current.map(\.lifecycleState) == sections.current.map(\.lifecycleState))
        #expect(reopenedSections.recentHistory == sections.recentHistory)
        // Restarted running work keeps the original recovery guard; rendering
        // it prominently never grants a control or invents a terminal result.
        #expect(reopenedSections.current.filter { $0.lifecycleState == .running || $0.lifecycleState == .approvalRequired }
            .allSatisfy { $0.recoveryState == .needsUserReview })
        #expect(recovered.filteredReceiptRows(archiveFilter, now: now) == fullHistory)
        #expect(reopened.taskCenterSnapshots(includeArchived: true) == snapshotsBefore)
        #expect(reopened.allReceipts() == receiptsBefore)
        #expect(try Data(contentsOf: file) == bytesBefore)
    }

    @Test func terminalReceiptRecencyFollowsSettlementRatherThanTaskIDOrStartOrder() throws {
        let root = try ownedRoot()
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(root) }
        let file = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: file)
        for id in ["z-first-start", "a-second-start"] {
            _ = try store.enqueue(taskID: id, parentID: "parent637", providerID: "offline", modelID: "fixture")
            _ = try store.startRun(taskID: id, parentID: "parent637", runID: "run-" + id)
        }
        _ = try store.finish(runID: "run-a-second-start", outcome: .succeeded)
        _ = try store.finish(runID: "run-z-first-start", outcome: .cancelled)
        let before = try Data(contentsOf: file)
        let consumer = TaskCenterControlConsumer(store: store)
        let sections = consumer.homeReceiptSections(TaskCenterReceiptFilter())
        #expect(sections.current.isEmpty)
        #expect(sections.recentHistory.map(\.taskID) == ["z-first-start", "a-second-start"])
        #expect(sections.recentHistory.map(\.lifecycleState) == [.cancelled, .completed])
        #expect(consumer.filteredReceiptRows(TaskCenterReceiptFilter(status: .completed)).map(\.taskID) == ["a-second-start"])
        #expect(try Data(contentsOf: file) == before)
    }

    private func ownedRoot() throws -> URL {
        try B1ARCHOriginalFixtureSupport.makeRoot("task637-original")
    }

    private func finishTask(_ store: AgentTaskStore, id: String, source: String,
                            outcome: AgentTaskOutcome) throws {
        // Reuse the existing filter/archive fixture's real canonical source
        // producer. A context snapshot ID is not a source-session identity.
        let identity = ParentRuntimeIdentity(sessionID: source,
            conversationID: "conversation-" + source, turnID: "turn-" + source,
            taskID: "parent637", actorID: "owned637")
        let creation = SessionActionCreationMetadata(scopeID: "scope637",
            idempotencyKey: "creation-" + id,
            action: .new(title: "Owned task " + id, projectID: "project637", source: identity))
        _ = try store.enqueueIdempotent(taskID: id, parentID: "parent637", providerID: "offline",
                                        modelID: "fixture", creation: creation)
        let run = try store.startRun(taskID: id, parentID: "parent637", runID: "run-" + id)
        _ = try store.finish(runID: run.runID, outcome: outcome)
    }
}
