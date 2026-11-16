import Foundation
import Testing
@testable import MinisCore

@Suite("TaskCenterObservationSnapshot")
struct TaskCenterObservationSnapshotTests {
    @Test func observationCapturesExistingViewModelAsAnImmutableReplayableValue() throws {
        let projection = TaskCenterProjection(snapshots: [
            snapshot(taskID: "queued", status: .queued),
            snapshot(taskID: "failed", status: .failed),
        ])
        let viewModel = TaskCenterViewModel(projection: projection)

        let observation = TaskCenterObservationSnapshot(viewModel: viewModel)

        #expect(observation.viewModel == viewModel)
        #expect(observation.projection == projection)
        #expect(observation.counts.failed == 1)
        #expect(observation.totalTasks == 2)
    }

    @Test func observationReadsStoreWithoutChangingItsProjectionAndRemainsHistoricalAfterLaterWrites() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "first",
            parentID: "parent",
            providerID: "provider",
            modelID: "model",
            routeReceiptID: "receipt"
        )
        let before = store.taskCenterProjection()

        let observation = TaskCenterObservationSnapshot(taskStore: store)

        #expect(observation.projection == before)
        #expect(store.taskCenterProjection() == before)

        _ = try store.enqueue(
            taskID: "later",
            parentID: "parent",
            providerID: "provider",
            modelID: "model",
            routeReceiptID: "receipt"
        )
        #expect(observation.totalTasks == 1)
        #expect(store.taskCenterProjection().totalTasks == 2)
    }

    @Test func equivalentObservationsEncodeDeterministicallyAndRoundTripAsSendableCodableValues() throws {
        let projection = TaskCenterProjection(snapshots: [
            snapshot(taskID: "running", status: .running),
            snapshot(taskID: "done", status: .succeeded),
        ])
        let first = TaskCenterObservationSnapshot(projection: projection)
        let second = TaskCenterObservationSnapshot(viewModel: TaskCenterViewModel(projection: projection))
        let capture: @Sendable () -> TaskCenterObservationSnapshot = { first }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        #expect(first == second)
        #expect(try encoder.encode(first) == encoder.encode(second))
        #expect(try JSONDecoder().decode(TaskCenterObservationSnapshot.self, from: encoder.encode(capture())) == first)
    }

    private func snapshot(taskID: String, status: AgentTaskStatus) -> AgentTaskSnapshot {
        AgentTaskSnapshot(
            taskID: taskID,
            parentID: "parent",
            parentContextSnapshotID: nil,
            providerID: "provider",
            modelID: "model",
            configurationFingerprint: "fingerprint",
            routeReceiptID: "receipt",
            status: status
        )
    }
}
