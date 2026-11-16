import Testing
@testable import MinisCore

@Suite("TaskCenterObservationSelector")
struct TaskCenterObservationSelectorTests {
    @Test func selectorAppliesEveryExplicitCriterionInDeterministicTaskOrder() {
        let observation = TaskCenterObservationSnapshot(snapshots: [
            snapshot(taskID: "task-z", parentID: "parent-b", providerID: "provider-a", modelID: "model-a", routeReceiptID: "receipt-a", status: .queued),
            snapshot(taskID: "task-a", parentID: "parent-a", providerID: "provider-a", modelID: "model-a", routeReceiptID: "receipt-a", status: .queued),
            snapshot(taskID: "task-b", parentID: "parent-a", providerID: "provider-b", modelID: "model-a", routeReceiptID: "receipt-a", status: .queued),
            snapshot(taskID: "task-c", parentID: "parent-a", providerID: "provider-a", modelID: "model-b", routeReceiptID: "receipt-a", status: .running),
        ])
        let filter = TaskCenterObservationFilter(
            statuses: [.queued],
            providerIDs: ["provider-a"],
            modelIDs: ["model-a"],
            routeReceiptIDs: ["receipt-a"]
        )

        let selected = observation.selecting(filter)

        #expect(selected.map(\.taskID) == ["task-a", "task-z"])
    }

    @Test func selectorFailsClosedForEmptyDuplicateOrInvalidIdentifierFilters() {
        let observation = TaskCenterObservationSnapshot(snapshots: [
            snapshot(taskID: "task-a", parentID: "parent-a", providerID: "provider-a", modelID: "model-a", routeReceiptID: "receipt-a", status: .queued),
        ])

        #expect(observation.selecting(TaskCenterObservationFilter(statuses: [])).isEmpty)
        #expect(observation.selecting(TaskCenterObservationFilter(taskIDs: ["task-a", "task-a"])).isEmpty)
        #expect(observation.selecting(TaskCenterObservationFilter(parentIDs: [" "])).isEmpty)
        #expect(observation.selecting(TaskCenterObservationFilter(providerIDs: [""])).isEmpty)
    }

    @Test func selectorDoesNotMutateCapturedObservationAndProducesSameResultAcrossReplays() {
        let snapshots = [
            snapshot(taskID: "task-b", parentID: "parent-a", providerID: "provider-a", modelID: nil, routeReceiptID: nil, status: .failed),
            snapshot(taskID: "task-a", parentID: "parent-a", providerID: "provider-a", modelID: nil, routeReceiptID: nil, status: .failed),
        ]
        let observation = TaskCenterObservationSnapshot(snapshots: snapshots)
        let filter = TaskCenterObservationFilter(statuses: [.failed], providerIDs: ["provider-a"])

        let first = observation.selecting(filter)
        let second = observation.selecting(filter)

        #expect(first == second)
        #expect(first.map(\.taskID) == ["task-a", "task-b"])
        #expect(observation.taskSnapshots == snapshots)
        #expect(observation.projection.totalTasks == 2)
    }

    private func snapshot(taskID: String, parentID: String, providerID: String?, modelID: String?, routeReceiptID: String?, status: AgentTaskStatus) -> AgentTaskSnapshot {
        AgentTaskSnapshot(taskID: taskID, parentID: parentID, parentContextSnapshotID: nil, providerID: providerID, modelID: modelID, configurationFingerprint: "fingerprint", routeReceiptID: routeReceiptID, status: status)
    }
}
