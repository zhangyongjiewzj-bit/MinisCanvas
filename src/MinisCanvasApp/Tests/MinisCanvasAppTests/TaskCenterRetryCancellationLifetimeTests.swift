import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("TaskCenter fresh retry cancellation owns actual child lifetime")
@MainActor
struct TaskCenterRetryCancellationLifetimeTests {
    @Test func stoppedFreshRetryJoinsAndRejectsLateActualProviderSuccess() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("task05-retry-cancel-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let tasksURL = root.appendingPathComponent("tasks.json")
        let tasks = try AgentTaskStore(persistenceURL: tasksURL)
        let provider = Task05RetryCancelProvider(workspace: workspace)
        var settingsOwner: SettingsCenter?
        defer { withExtendedLifetime(settingsOwner) {} }
        let bridge = try await TaskCenterRetryProductionFixtureSupport.makeBridge(root: root, store: tasks, provider: provider,
            runner: Task05RetryCancelRunner(), retainSettingsOwner: { settingsOwner = $0 })
        try #require(settingsOwner != nil && SettingsCenter.active === settingsOwner)
        let chat = bridge.chat
        chat.draftText = "owned task05 first request"
        chat.submitComposer()
        let firstDeadline = Date().addingTimeInterval(5)
        while Date() < firstDeadline && (chat.isStreaming || provider.childCalls == 0) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!chat.isStreaming)
        try #require(provider.childCalls == 1)
        let row = try #require(bridge.taskCenterControlConsumer.receiptRows().first {
            $0.taskID == "task05-cancel-child" && $0.lifecycleState == .failed
        })
        let oldRunID = try #require(row.runID)
        let oldReceipt = try #require(tasks.receipt(runID: oldRunID))
        let fact = try #require(bridge.taskCenterGoalProjection().fact(taskID: row.taskID, parentID: row.parentID))
        let request = TaskCenterControlRequest(taskID: row.taskID, parentID: row.parentID,
            revision: fact.revision, scopeID: try #require(fact.scopeID), actorID: "task-center-ui",
            idempotencyKey: "task05-owned-cancel-\(UUID().uuidString)", action: .retry, runID: oldRunID)
        let actualRetry = Task { @MainActor in
            do {
                return try await bridge.executeTaskCenterRetryFromUserEvent(request)
            } catch {
                print("TASK05_OWNED_RETRY_ERROR=" + String(reflecting: error))
                print("TASK05_OWNED_RETRY_CHILD_CALLS=" + String(provider.childCalls))
                throw error
            }
        }
        defer { provider.releaseActualResponse() }
        let heldDeadline = Date().addingTimeInterval(5)
        while Date() < heldDeadline && !provider.isHeld { try await Task.sleep(for: .milliseconds(5)) }
        try #require(provider.isHeld && provider.childCalls == 2)
        let newRunID = try #require(tasks.controlSnapshot(taskID: row.taskID, parentID: row.parentID)?.runID)
        #expect(newRunID != oldRunID)
        let newBinding = try #require(tasks.retryRunRuntimeBinding(runID: newRunID))
        #expect(newBinding.originalParentID == row.parentID)
        #expect(newBinding.parent.taskID != row.parentID)
        #expect(newBinding.child.parentTaskID == newBinding.parent.taskID)
        try #require(chat.isStreaming)
        chat.stopStreaming()
        let cancelledDeadline = Date().addingTimeInterval(2)
        while Date() < cancelledDeadline && !provider.sawCancellation { try await Task.sleep(for: .milliseconds(5)) }
        #expect(provider.sawCancellation)
        provider.releaseActualResponse()
        let controlReceipt = try await actualRetry.value
        #expect(controlReceipt.resultingRunID == newRunID)
        try #require(await bridge.joinTaskCenterRetryExecution(runID: newRunID) != nil)
        let newReceipt = try #require(tasks.receipt(runID: newRunID))
        #expect(newReceipt.outcome == .cancelled)
        #expect(tasks.receipt(runID: oldRunID) == oldReceipt)
        #expect(provider.childCalls == 2)
        #expect(!chat.isStreaming)
        #expect(!chat.messages.contains { $0.content.contains("TASK05_LATE_REMOTE_SUCCESS_MUST_NOT_COMMIT") })
        let child = try #require(newReceipt.childResultEnvelope?.childTranscriptLocator)
        #expect(child.parentID == row.parentID)
        #expect(child.runtimeParentID == newBinding.parent.taskID)
        #expect(child.runID == newRunID)
        let session = try #require(chat.sessionStore?.loadSession(id: child.childSessionID))
        #expect(session.createdByRunID == newRunID)
        #expect(!session.messages.contains { $0.content.contains("TASK05_LATE_REMOTE_SUCCESS_MUST_NOT_COMMIT") })
        let reopened = try AgentTaskStore(persistenceURL: tasksURL)
        #expect(reopened.receipt(runID: oldRunID) == oldReceipt)
        #expect(reopened.receipt(runID: newRunID) == newReceipt)
    }
}
