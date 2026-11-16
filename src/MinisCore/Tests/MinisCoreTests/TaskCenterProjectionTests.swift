import Foundation
import Testing
@testable import MinisCore

/// P3-A6-TASK-CENTER-CONTRACT-20260815：任务中心只读投影契约（RED 先行）。
///
/// 契约点：
/// 1. 只读：投影仅消费既有 AgentTaskSnapshot 值，不修改任何 store、
///    不持久化、不引入新事实源；相同输入恒得相同投影。
/// 2. 按 status 聚合计数：queued/running/succeeded/failed/cancelled 五类
///    各计一个，total == 快照总数 == 五类之和。
/// 3. 保留 provider/model/routeReceiptID 绑定：对 providerID 非空的快照，
///    去重保留 (providerID, modelID, routeReceiptID) 三元组，顺序确定性排序。
/// 4. 未绑定快照（providerID == nil）计入计数但不进入绑定集合。
/// 5. 空输入 → 全零计数、空绑定集合。
/// 6. 不可变值类型：全部属性为 let，Sendable + Codable，JSON 往返无损。
struct TaskCenterProjectionTests {

    private func makeSnapshot(
        taskID: String = "task-a",
        parentID: String = "parent-a",
        providerID: String? = "provider-a",
        modelID: String? = "model-a",
        routeReceiptID: String? = "receipt-a",
        status: AgentTaskStatus = .queued
    ) -> AgentTaskSnapshot {
        AgentTaskSnapshot(
            taskID: taskID,
            parentID: parentID,
            parentContextSnapshotID: nil,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: "fp-a",
            routeReceiptID: routeReceiptID,
            status: status
        )
    }

    // MARK: - 不可变 / Sendable / Codable

    @Test func projectionIsImmutableSendableCodableValueType() throws {
        let base = TaskCenterProjection(snapshots: [makeSnapshot(), makeSnapshot(status: .succeeded)])
        // Sendable 编译期证明：投影可在 @Sendable 闭包间无竞争传递。
        let sendableCapture: @Sendable () -> TaskCenterProjection = { base }
        let captured = sendableCapture()
        #expect(captured == base)
        // JSON 往返无损。
        let data = try JSONEncoder().encode(base)
        let decoded = try JSONDecoder().decode(TaskCenterProjection.self, from: data)
        #expect(decoded == base)
    }

    // MARK: - 按 status 聚合计数

    @Test func projectionCountsAllFiveStatuses() {
        let snapshots = [
            makeSnapshot(taskID: "t1", status: .queued),
            makeSnapshot(taskID: "t2", status: .running),
            makeSnapshot(taskID: "t3", status: .succeeded),
            makeSnapshot(taskID: "t4", status: .failed),
            makeSnapshot(taskID: "t5", status: .cancelled),
            makeSnapshot(taskID: "t6", status: .queued),
        ]
        let projection = TaskCenterProjection(snapshots: snapshots)
        #expect(projection.counts.queued == 2)
        #expect(projection.counts.running == 1)
        #expect(projection.counts.succeeded == 1)
        #expect(projection.counts.failed == 1)
        #expect(projection.counts.cancelled == 1)
        #expect(projection.counts.total == 6)
        #expect(projection.totalTasks == 6)
    }

    @Test func projectionTotalEqualsSnapshotCountAndSumOfCounts() {
        let snapshots = (0..<9).map { index in
            makeSnapshot(
                taskID: "t\(index)",
                status: [AgentTaskStatus.queued, .running, .succeeded, .failed, .cancelled][index % 5]
            )
        }
        let projection = TaskCenterProjection(snapshots: snapshots)
        let summed = projection.counts.queued + projection.counts.running
            + projection.counts.succeeded + projection.counts.failed + projection.counts.cancelled
        #expect(summed == projection.counts.total)
        #expect(projection.counts.total == snapshots.count)
        #expect(projection.totalTasks == snapshots.count)
    }

    // MARK: - 保留 provider/model/routeReceiptID 绑定

    @Test func projectionPreservesDistinctRouteBindings() {
        let snapshots = [
            makeSnapshot(taskID: "t1", providerID: "p1", modelID: "m1", routeReceiptID: "r1", status: .succeeded),
            makeSnapshot(taskID: "t2", providerID: "p1", modelID: "m1", routeReceiptID: "r1", status: .running),
            makeSnapshot(taskID: "t3", providerID: "p2", modelID: "m2", routeReceiptID: "r2", status: .queued),
            makeSnapshot(taskID: "t4", providerID: "p2", modelID: "m2", routeReceiptID: nil, status: .queued),
        ]
        let projection = TaskCenterProjection(snapshots: snapshots)
        #expect(projection.bindings.count == 3)
        #expect(projection.bindings.contains(TaskCenterProjection.RouteBinding(providerID: "p1", modelID: "m1", routeReceiptID: "r1")))
        #expect(projection.bindings.contains(TaskCenterProjection.RouteBinding(providerID: "p2", modelID: "m2", routeReceiptID: "r2")))
        #expect(projection.bindings.contains(TaskCenterProjection.RouteBinding(providerID: "p2", modelID: "m2", routeReceiptID: nil)))
    }

    @Test func projectionExcludesUnboundSnapshotsFromBindingsButCountsThem() {
        let snapshots = [
            makeSnapshot(taskID: "t1", providerID: "p1", modelID: "m1", routeReceiptID: "r1", status: .running),
            makeSnapshot(taskID: "t2", providerID: nil, modelID: nil, routeReceiptID: nil, status: .queued),
            makeSnapshot(taskID: "t3", providerID: nil, modelID: nil, routeReceiptID: nil, status: .succeeded),
        ]
        let projection = TaskCenterProjection(snapshots: snapshots)
        #expect(projection.counts.queued == 1)
        #expect(projection.counts.running == 1)
        #expect(projection.counts.succeeded == 1)
        #expect(projection.totalTasks == 3)
        #expect(projection.bindings.count == 1)
        #expect(projection.bindings == [TaskCenterProjection.RouteBinding(providerID: "p1", modelID: "m1", routeReceiptID: "r1")])
    }

    @Test func projectionBindingsOrderIsDeterministic() {
        let input = [
            makeSnapshot(taskID: "t1", providerID: "b-provider", modelID: "b-model", routeReceiptID: "b-receipt"),
            makeSnapshot(taskID: "t2", providerID: "a-provider", modelID: "a-model", routeReceiptID: "a-receipt"),
            makeSnapshot(taskID: "t3", providerID: "a-provider", modelID: "a-model", routeReceiptID: "a-receipt"),
        ]
        let forward = TaskCenterProjection(snapshots: input)
        let reversed = TaskCenterProjection(snapshots: Array(input.reversed()))
        #expect(forward == reversed)
        #expect(forward.bindings == [
            TaskCenterProjection.RouteBinding(providerID: "a-provider", modelID: "a-model", routeReceiptID: "a-receipt"),
            TaskCenterProjection.RouteBinding(providerID: "b-provider", modelID: "b-model", routeReceiptID: "b-receipt"),
        ])
    }

    // MARK: - 只读 / 空输入

    @Test func projectionEmptyInputYieldsZeroCountsAndEmptyBindings() {
        let projection = TaskCenterProjection(snapshots: [])
        #expect(projection.counts.queued == 0)
        #expect(projection.counts.running == 0)
        #expect(projection.counts.succeeded == 0)
        #expect(projection.counts.failed == 0)
        #expect(projection.counts.cancelled == 0)
        #expect(projection.counts.total == 0)
        #expect(projection.totalTasks == 0)
        #expect(projection.bindings.isEmpty)
    }

    @Test func projectionIsReadOnlyAndReplayable() {
        let input = [
            makeSnapshot(taskID: "t1", status: .running),
            makeSnapshot(taskID: "t2", status: .succeeded),
        ]
        let first = TaskCenterProjection(snapshots: input)
        let second = TaskCenterProjection(snapshots: input)
        #expect(first == second)
        #expect(input.count == 2)
    }
}
