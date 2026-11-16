import Foundation
import Testing
@testable import MinisCore

@Suite("TaskCenterViewModel")
struct TaskCenterViewModelTests {
    private func makeSnapshot(
        taskID: String,
        providerID: String? = "provider-a",
        modelID: String? = "model-a",
        routeReceiptID: String? = "receipt-a",
        status: AgentTaskStatus
    ) -> AgentTaskSnapshot {
        AgentTaskSnapshot(
            taskID: taskID,
            parentID: "parent-a",
            parentContextSnapshotID: nil,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: "fingerprint-a",
            routeReceiptID: routeReceiptID,
            status: status
        )
    }

    @Test func viewModelReplaysExistingProjectionWithoutChangingIt() throws {
        let projection = TaskCenterProjection(snapshots: [
            makeSnapshot(taskID: "queued", status: .queued),
            makeSnapshot(taskID: "running", status: .running),
            makeSnapshot(taskID: "done", status: .succeeded),
        ])

        let viewModel = TaskCenterViewModel(projection: projection)

        #expect(viewModel.projection == projection)
        #expect(viewModel.totalTasks == 3)
        #expect(viewModel.counts.running == 1)
        #expect(viewModel.routeBindings == projection.bindings)
    }

    @Test func viewModelQueriesStoreReadOnlyThroughProjectionBoundary() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "task-a",
            parentID: "parent-a",
            providerID: "provider-a",
            modelID: "model-a",
            routeReceiptID: "receipt-a"
        )
        let before = store.taskCenterProjection()

        let viewModel = TaskCenterViewModel(taskStore: store)

        #expect(viewModel.projection == before)
        #expect(store.taskCenterProjection() == before)
    }

    @Test func viewModelIsSendableCodableValue() throws {
        let viewModel = TaskCenterViewModel(projection: TaskCenterProjection(snapshots: [
            makeSnapshot(taskID: "failed", providerID: nil, modelID: nil, routeReceiptID: nil, status: .failed),
        ]))
        let capture: @Sendable () -> TaskCenterViewModel = { viewModel }

        let data = try JSONEncoder().encode(capture())
        #expect(try JSONDecoder().decode(TaskCenterViewModel.self, from: data) == viewModel)
    }
}
