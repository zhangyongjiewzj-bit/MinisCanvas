import Foundation

/// Immutable task-center presentation contract derived from the canonical task ledger.
///
/// This value intentionally exposes no task lifecycle or persistence mutations. UI clients
/// can refresh it from an AgentTaskStore, while tests and non-UI consumers can replay a
/// previously captured TaskCenterProjection directly.
public struct TaskCenterViewModel: Sendable, Equatable, Codable {
    public let projection: TaskCenterProjection
    /// Captured rows are retained when the model is created from a store.
    /// A projection-only model intentionally has no row detail to replay.
    public let taskSnapshots: [AgentTaskSnapshot]

    public var counts: TaskCenterProjection.Counts { projection.counts }
    public var totalTasks: Int { projection.totalTasks }
    public var routeBindings: [TaskCenterProjection.RouteBinding] { projection.bindings }

    public init(projection: TaskCenterProjection, taskSnapshots: [AgentTaskSnapshot] = []) {
        self.projection = projection
        self.taskSnapshots = taskSnapshots
    }

    public init(snapshots: [AgentTaskSnapshot]) {
        self.init(
            projection: TaskCenterProjection(snapshots: snapshots),
            taskSnapshots: snapshots
        )
    }

    public init(taskStore: AgentTaskStore) {
        self.init(snapshots: taskStore.taskCenterSnapshots())
    }
}
