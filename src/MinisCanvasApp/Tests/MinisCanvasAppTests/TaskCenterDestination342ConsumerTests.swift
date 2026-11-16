import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Source-only consumer regressions. Real NavigationStack press/pop, filter and
/// scroll-position preservation remain a native/package acceptance boundary.
@Suite("D-TASK-12 source/result canonical consumers")
@MainActor
struct TaskCenterDestination342ConsumerTests {
    @Test("opening task destinations preserves the active parent composer and persisted sessions")
    func destinationReadsPreserveParentState() throws {
        let root = temporaryRoot()
        let suite = "task342-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let sourceID = UUID()
        let activeID = UUID()
        _ = try sessions.createSession(id: sourceID.uuidString, title: "任务来源")
        _ = try sessions.createSession(id: activeID.uuidString, title: "当前父视图")
        try sessions.saveMessage(LLMMessage(role: .user, content: "任务原请求"), sessionID: sourceID.uuidString)
        try sessions.saveMessage(LLMMessage(role: .assistant, content: "父视图历史"), sessionID: activeID.uuidString)
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        #expect(chat.attachPersistence(sessions))
        #expect(chat.applySwitchSession(id: activeID))
        chat.draftText = "原视图未发送正文"
        let originalSource = try #require(sessions.loadSession(id: sourceID.uuidString))
        let originalActive = try #require(sessions.loadSession(id: activeID.uuidString))

        let tasks = AgentTaskStore()
        let source = ParentRuntimeIdentity(sessionID: sourceID.uuidString,
            conversationID: "conversation342", turnID: "turn342", taskID: "parent342", actorID: "actor342")
        let creation = SessionActionCreationMetadata(scopeID: "scope342", idempotencyKey: "create342",
            action: .new(title: "来源任务", projectID: "synthetic342", source: source))
        let task = try tasks.enqueueIdempotent(taskID: "source-task342", parentID: "parent342",
            providerID: "offline", modelID: "synthetic", creation: creation).snapshot
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "read342")
        _ = try tasks.settleChildResult(result(task: task, runID: run.runID, output: "本次结果"))
        let consumer = TaskCenterControlConsumer(store: tasks, childTranscriptSessionStore: sessions)
        let row = try #require(consumer.receiptRows().first)
        let sourceNavigation = try #require(consumer.sourceSessionNavigation(for: row))
        let resultNavigation = try #require(consumer.resultNavigation(for: row))
        let originalEvents = tasks.events(runID: run.runID)
        let originalReceipt = tasks.receipt(runID: run.runID)

        #expect(consumer.sourceTranscript(navigation: sourceNavigation)?.messages.map(\.content) == ["任务原请求"])
        #expect(consumer.resultDetail(navigation: resultNavigation)?.displayOutput == "本次结果")
        #expect(chat.activeSessionID == activeID)
        #expect(chat.draftText == "原视图未发送正文")
        #expect(!chat.isStreaming)
        #expect(sessions.loadSession(id: sourceID.uuidString) == originalSource)
        #expect(sessions.loadSession(id: activeID.uuidString) == originalActive)
        #expect(tasks.events(runID: run.runID) == originalEvents)
        #expect(tasks.receipt(runID: run.runID) == originalReceipt)

        // Archive is a visibility preference. The real destination consumer
        // must keep the settled source/result readable without restoring or
        // redispatching the task just to navigate from the archive list.
        _ = try consumer.applyArchive(TaskCenterArchiveRequest(
            taskID: task.taskID, parentID: task.parentID,
            actorID: "synthetic-archive342", idempotencyKey: "archive342",
            action: .archive
        ))
        let archived = try #require(consumer.filteredReceiptRows(
            TaskCenterReceiptFilter(includeArchived: true)
        ).first { $0.taskID == task.taskID })
        #expect(archived.isArchived)
        let archivedEvents = tasks.events(runID: run.runID)
        let archivedSource = try #require(consumer.sourceSessionNavigation(for: archived))
        let archivedResult = try #require(consumer.resultNavigation(for: archived))
        #expect(consumer.sourceTranscript(navigation: archivedSource)?.messages.map(\.content) == ["任务原请求"])
        #expect(consumer.resultDetail(navigation: archivedResult)?.displayOutput == "本次结果")
        #expect(consumer.receiptRows().isEmpty)
        #expect(tasks.snapshot(taskID: task.taskID, parentID: task.parentID)?.isArchived == true)
        #expect(tasks.events(runID: run.runID) == archivedEvents)
        #expect(chat.activeSessionID == activeID)
        #expect(chat.draftText == "原视图未发送正文")
    }

    @Test("removing the canonical session binding invalidates an already opened source")
    func detachedSessionBindingClosesSource() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let source = try sessions.createSession(id: "bound-source342")
        let tasks = AgentTaskStore()
        let identity = ParentRuntimeIdentity(sessionID: source.id, conversationID: "conversation",
            turnID: "turn", taskID: "parent", actorID: "actor")
        let creation = SessionActionCreationMetadata(scopeID: "scope", idempotencyKey: "create",
            action: .new(title: "已绑定来源", projectID: "synthetic", source: identity))
        _ = try tasks.enqueueIdempotent(taskID: "bound-task", parentID: "parent",
            providerID: "offline", modelID: "synthetic", creation: creation)
        let consumer = TaskCenterControlConsumer(store: tasks, childTranscriptSessionStore: sessions)
        let row = try #require(consumer.receiptRows().first)
        let navigation = try #require(consumer.sourceSessionNavigation(for: row))
        #expect(consumer.sourceTranscript(navigation: navigation) != nil)
        consumer.bindChildTranscriptSessionStore(nil)
        #expect(consumer.sourceSessionNavigation(for: row) == nil)
        #expect(consumer.sourceTranscript(navigation: navigation) == nil)
        consumer.bindChildTranscriptSessionStore(sessions)
        #expect(consumer.sourceTranscript(navigation: navigation) != nil)
    }

    @Test("row navigation does not decode a session; destination rejects malformed lineage payload")
    func malformedSourceIsRejectedOnlyAtContentBoundary() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let source = try sessions.createSession(id: "malformed-source342")
        let tasks = AgentTaskStore()
        let identity = ParentRuntimeIdentity(sessionID: source.id, conversationID: "conversation",
            turnID: "turn", taskID: "parent", actorID: "actor")
        let creation = SessionActionCreationMetadata(scopeID: "scope", idempotencyKey: "create",
            action: .new(title: "按需读取来源", projectID: "synthetic", source: identity))
        _ = try tasks.enqueueIdempotent(taskID: "malformed-task", parentID: "parent",
            providerID: "offline", modelID: "synthetic", creation: creation)
        let consumer = TaskCenterControlConsumer(store: tasks, childTranscriptSessionStore: sessions)
        let row = try #require(consumer.receiptRows().first)
        let file = sessions.sessionsDirectory.appendingPathComponent("\(source.id).json")
        let invalidBytes = Data("malformed synthetic session".utf8)
        try invalidBytes.write(to: file)
        // A provenance-based link is advisory, never permission to display
        // content. Only SessionStore's full lineage read can admit the page.
        let navigation = try #require(consumer.sourceSessionNavigation(for: row))
        #expect(consumer.sourceTranscript(navigation: navigation) == nil)
        #expect(try Data(contentsOf: file) == invalidBytes)
        try JSONEncoder().encode(source).write(to: file)
        #expect(consumer.sourceTranscript(navigation: navigation) != nil)
    }

    @Test("evidence references never become file destinations or unbounded output")
    func resultDetailIsBoundedAndRejectsForeignIdentity() throws {
        let tasks = AgentTaskStore()
        let task = try tasks.enqueue(taskID: "bounded342", parentID: "parent342",
            providerID: "offline", modelID: "synthetic")
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "bounded-run342")
        let reference = "file:///synthetic-private-reference342"
        _ = try tasks.settleChildResult(result(task: task, runID: run.runID,
            output: String(repeating: "正文", count: 3_000), references: [reference]))
        let consumer = TaskCenterControlConsumer(store: tasks)
        let row = try #require(consumer.receiptRows().first)
        let navigation = try #require(consumer.resultNavigation(for: row))
        let detail = try #require(consumer.resultDetail(navigation: navigation))
        #expect((detail.displayOutput?.count ?? 0) <= 4_096)
        #expect(detail.evidenceCount == 1)
        #expect(!String(describing: detail).contains(reference))
        for (parentID, runID, resultKey) in [
            ("foreign-parent", navigation.runID, navigation.resultIdempotencyKey),
            (navigation.parentID, "foreign-run", navigation.resultIdempotencyKey),
            (navigation.parentID, navigation.runID, "foreign-result")
        ] {
            let foreign = TaskCenterResultNavigation(taskID: navigation.taskID, parentID: parentID,
                runID: runID, attemptID: navigation.attemptID, resultIdempotencyKey: resultKey)
            #expect(consumer.resultDetail(navigation: foreign) == nil)
        }
    }

    @Test("a real canonical retry removes the previous result destination")
    func retryInvalidatesPreviouslyOpenedResult() throws {
        let tasks = AgentTaskStore()
        let task = try tasks.enqueue(taskID: "retry342", parentID: "parent342",
            providerID: "offline", modelID: "synthetic")
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "old342")
        _ = try tasks.settleChildResult(result(task: task, runID: run.runID,
            output: "旧次结果", outcome: .failed(reason: "synthetic-detail-before-normalization")))
        let consumer = TaskCenterControlConsumer(store: tasks)
        let now = Date()
        let goal = GoalEnvelope(goalID: UUID(), scopeID: "retry342", allowedCapabilities: ["task.control"],
            budget: 10, deadline: now.addingTimeInterval(3_600), createdAt: now.addingTimeInterval(-60))
        let lease = AutonomyLease(leaseID: UUID(), goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-60), expiresAt: goal.deadline)
        consumer.installProductionGoal(goal: goal, lease: lease)
        let row = try #require(consumer.receiptRows(now: now).first)
        let navigation = try #require(consumer.resultNavigation(for: row))
        // The receipt normalizes the reason; the canonical envelope preserves
        // the actual result. Their raw outcomes need not be equal.
        #expect(tasks.receipt(runID: run.runID)?.outcome == .failed(reason: "execution-failed"))
        #expect(consumer.resultDetail(navigation: navigation)?.displayOutput == "旧次结果")
        let fact = try #require(consumer.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        _ = try consumer.execute(TaskCenterControlRequest(taskID: task.taskID, parentID: task.parentID,
            revision: fact.revision, scopeID: goal.scopeID, actorID: "actor342", idempotencyKey: "retry342",
            action: .retry, runID: run.runID), now: now)
        #expect(consumer.resultNavigation(for: row) == nil)
        #expect(consumer.resultDetail(navigation: navigation) == nil)
        #expect(tasks.receipt(runID: run.runID)?.outcome == .failed(reason: "execution-failed"))
    }

    @Test("evidence-only results open a bounded result page; empty results have no destination", arguments: [false, true])
    func evidenceOnlyAndEmptyResultsStayDistinct(hasEvidence: Bool) throws {
        let tasks = AgentTaskStore()
        let task = try tasks.enqueue(taskID: "evidence342", parentID: "parent342",
            providerID: "offline", modelID: "synthetic")
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "evidence-run342")
        _ = try tasks.settleChildResult(result(task: task, runID: run.runID,
            output: nil, references: hasEvidence ? ["file:///synthetic-reference342"] : []))
        let consumer = TaskCenterControlConsumer(store: tasks)
        let row = try #require(consumer.receiptRows().first)
        let navigation = consumer.resultNavigation(for: row)
        if hasEvidence {
            let openedNavigation = try #require(navigation)
            let detail = try #require(consumer.resultDetail(navigation: openedNavigation))
            #expect(detail.displayOutput == nil)
            #expect(detail.evidenceCount == 1)
        } else {
            #expect(navigation == nil)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("task342-\(UUID().uuidString)", isDirectory: true)
    }

    private func result(task: AgentTaskSnapshot, runID: String, output: String?,
                        references: [String] = [], outcome: AgentTaskOutcome = .succeeded) -> ChildResultEnvelope {
        ChildResultEnvelope(taskID: task.taskID, runID: runID, attemptID: "\(runID):attempt:1",
            parentContextSnapshotID: task.parentContextSnapshotID, childExecutionID: "execution-\(runID)",
            outcome: outcome, outputDigest: "digest-\(runID)", evidenceRefs: references, output: output)
    }
}
