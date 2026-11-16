import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class ProjectTaskDeferredCleanupGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var isFirstRead = true

    func holdFirstRead() {
        lock.lock()
        let shouldHold = isFirstRead
        isFirstRead = false
        lock.unlock()
        guard shouldHold else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
    }

    func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: entered.wait(timeout: .now() + 10) == .success)
            }
        }
    }

    func resume() { release.signal() }
}

@Suite("Project task deferred cleanup identity")
@MainActor
struct ProjectTaskDeferredCleanupIdentityTests {
    @Test("Project task failures retain the same safe category in the target and durable receipt",
          arguments: [false, true])
    func projectFailureCategorySurvivesTheActualRunConsumer(missingRuntime: Bool) async throws {
        let instruction = "owned project failure input"
        let fixture = try ScheduledTargetFixture(command: instruction, projectChildTarget: true)
        defer { fixture.cleanup() }
        // The real project launcher preflights the target's inherited model
        // before starting a turn. Match the explicit owned selection already
        // used by the sibling deferred-cleanup consumer below.
        fixture.chat.restoreSpeedTier(.fast)
        fixture.chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root),
            requestBudget: fixture.chat.budgetTracker,
            composerPolicyFacts: fixture.chat.composerPolicyFacts)
        try #require(fixture.chat.turnRuntimeSnapshotFactory == nil)
        let store = AgentTaskStore()
        let taskID = "owned-failure-task"
        let runID = "owned-failure-run"
        _ = try store.enqueue(taskID: taskID, parentID: "owned-parent", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: taskID, runID: runID)
        var authorizationChecks = 0
        let started = fixture.chat.startProjectTask(targetID: fixture.targetID.uuidString,
            projectID: fixture.projectID, instruction: instruction, runID: runID,
            taskStore: store, authorization: {
                authorizationChecks += 1
                return missingRuntime || authorizationChecks == 1
            }, onFinished: {})
        try #require(started)
        let running = try #require(fixture.chat.turnTaskForTests(sessionID: fixture.targetID))
        await running.value
        let expected = missingRuntime
            ? "执行校验未通过（CHAT-RUNTIME:missingRequiredSnapshot），本次请求未完成。"
            : "执行校验未通过（PROJECT:targetUnavailable），本次请求未完成。"
        #expect(authorizationChecks >= 2)
        let execution = try #require(fixture.chat.executionSnapshot(forSessionID: fixture.targetID))
        #expect(execution.state == .failed && execution.failureReason == expected)
        let receipt = try #require(store.allReceipts().first { $0.runID == runID })
        #expect(receipt.outcome == .failed(reason: expected))
        let category = missingRuntime ? AgentTaskPublicFailureCategory.chatRuntimeMissingRequiredSnapshot
            : .projectTargetUnavailable
        #expect(store.publicFailureCategory(for: receipt) == category)
        let consumer = TaskCenterControlConsumer(store: store)
        let row = try #require(consumer.receiptRows().first { $0.taskID == taskID && $0.runID == runID })
        #expect(row.lifecycleState == .failed && row.failureReason == expected)
        #expect(row.failureReasonDisplayTitle == (missingRuntime ? "缺少冻结运行快照" : "目标会话不可用"))
        #expect(row.accessibilityLabel.contains(expected))
        #expect(fixture.persistence.loadSession(id: fixture.targetID.uuidString)?.messages == fixture.original)
        #expect(!fixture.chat.hasStreamingTasksForSafety)
    }

    @Test func cancelledProjectTailKeepsNewComposerTaskHandle() async throws {
        let instruction = "old project prompt"
        let fixture = try ScheduledTargetFixture(command: instruction, projectChildTarget: true)
        let gate = ProjectTaskDeferredCleanupGate()
        defer {
            gate.resume()
            fixture.cleanup()
        }
        fixture.chat.restoreSpeedTier(.fast)
        let memoryDirectory = fixture.root.appendingPathComponent("memory-root", isDirectory: true)
        try MemoryStore(directory: memoryDirectory).addFact(
            "isolated project memory fact",
            sourceSessionID: fixture.targetID.uuidString,
            memoryScope: MemoryScope(sessionID: fixture.targetID.uuidString, projectID: fixture.projectID)
        )
        fixture.chat.memoryEnabledProvider = { true }
        fixture.chat.memoryInjector = MemoryInjector(store: MemoryStore(
            directory: memoryDirectory,
            lifecycleTransactionFaultInjector: nil,
            beforeFactsReadForTesting: { gate.holdFirstRead() }
        ))
        let taskStore = AgentTaskStore()
        let taskID = "old-project-task"
        let runID = "old-project-run"
        _ = try taskStore.enqueue(taskID: taskID, parentID: "project-parent", providerID: nil, modelID: nil)
        _ = try taskStore.startRun(taskID: taskID, runID: runID)

        #expect(fixture.chat.applySwitchSession(id: fixture.targetID))
        let started = fixture.chat.startProjectTask(
            targetID: fixture.targetID.uuidString,
            projectID: fixture.projectID,
            instruction: instruction,
            runID: runID,
            taskStore: taskStore,
            authorization: { true },
            onFinished: {}
        )
        #expect(started)
        let entered = await gate.waitForEntry()
        #expect(entered)
        let oldTask = try #require(fixture.chat.turnTaskForTests(sessionID: fixture.targetID))

        fixture.chat.stopStreamingForSwitch()
        #expect(fixture.chat.turnTaskForTests(sessionID: fixture.targetID) == nil)
        fixture.chat.draftText = "new composer prompt"
        fixture.chat.submitComposer()
        let newTask = try #require(fixture.chat.turnTaskForTests(sessionID: fixture.targetID))
        #expect(newTask != oldTask)
        #expect(fixture.chat.messages.count == 3)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(fixture.chat.turnTaskForTests(sessionID: fixture.targetID) == newTask)

        gate.resume()
        await oldTask.value
        #expect(fixture.chat.turnTaskForTests(sessionID: fixture.targetID) == newTask)
        fixture.chat.stopStreamingForSwitch()
    }
}
