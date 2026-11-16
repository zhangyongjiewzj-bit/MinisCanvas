import Foundation

/// Immutable, fail-closed selector criteria for captured task-center observations.
///
/// Every supplied criterion must contain at least one unique, nonblank value. An invalid
/// criterion makes the whole filter invalid; callers therefore receive no task facts rather
/// than an ambiguous broad result.
public struct TaskCenterObservationFilter: Sendable, Equatable, Codable {
    public let taskIDs: [String]?
    public let parentIDs: [String]?
    public let statuses: [AgentTaskStatus]?
    public let providerIDs: [String]?
    public let modelIDs: [String]?
    public let routeReceiptIDs: [String]?
    public let sourceSessionIDs: [String]?
    public let includeArchived: Bool

    private enum CodingKeys: String, CodingKey {
        case taskIDs, parentIDs, statuses, providerIDs, modelIDs, routeReceiptIDs
        case sourceSessionIDs, includeArchived
    }

    public init(
        taskIDs: [String]? = nil,
        parentIDs: [String]? = nil,
        statuses: [AgentTaskStatus]? = nil,
        providerIDs: [String]? = nil,
        modelIDs: [String]? = nil,
        routeReceiptIDs: [String]? = nil,
        sourceSessionIDs: [String]? = nil,
        includeArchived: Bool = false
    ) {
        self.taskIDs = taskIDs
        self.parentIDs = parentIDs
        self.statuses = statuses
        self.providerIDs = providerIDs
        self.modelIDs = modelIDs
        self.routeReceiptIDs = routeReceiptIDs
        self.sourceSessionIDs = sourceSessionIDs
        self.includeArchived = includeArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskIDs = try container.decodeIfPresent([String].self, forKey: .taskIDs)
        parentIDs = try container.decodeIfPresent([String].self, forKey: .parentIDs)
        statuses = try container.decodeIfPresent([AgentTaskStatus].self, forKey: .statuses)
        providerIDs = try container.decodeIfPresent([String].self, forKey: .providerIDs)
        modelIDs = try container.decodeIfPresent([String].self, forKey: .modelIDs)
        routeReceiptIDs = try container.decodeIfPresent([String].self, forKey: .routeReceiptIDs)
        sourceSessionIDs = try container.decodeIfPresent([String].self, forKey: .sourceSessionIDs)
        includeArchived = try container.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false
    }

    fileprivate var isValid: Bool {
        validIdentifiers(taskIDs)
            && validIdentifiers(parentIDs)
            && validValues(statuses)
            && validIdentifiers(providerIDs)
            && validIdentifiers(modelIDs)
            && validIdentifiers(routeReceiptIDs)
            && validIdentifiers(sourceSessionIDs)
    }

    private func validIdentifiers(_ values: [String]?) -> Bool {
        guard let values else { return true }
        return !values.isEmpty
            && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(values).count == values.count
    }

    private func validValues<Value: Hashable>(_ values: [Value]?) -> Bool {
        guard let values else { return true }
        return !values.isEmpty && Set(values).count == values.count
    }
}

/// Immutable read-only task-center observation captured from existing task snapshots.
///
/// This snapshot never mutates task lifecycle state, persistence, GUI state, accessibility
/// state, or bridge stores. It is suitable for deterministic replay by non-UI consumers.
public struct TaskCenterObservationSnapshot: Sendable, Equatable, Codable {
    public let viewModel: TaskCenterViewModel
    public let taskSnapshots: [AgentTaskSnapshot]

    public var projection: TaskCenterProjection { viewModel.projection }
    public var counts: TaskCenterProjection.Counts { viewModel.counts }
    public var totalTasks: Int { viewModel.totalTasks }
    public var routeBindings: [TaskCenterProjection.RouteBinding] { viewModel.routeBindings }

    public init(snapshots: [AgentTaskSnapshot]) {
        let viewModel = TaskCenterViewModel(snapshots: snapshots)
        self.viewModel = viewModel
        self.taskSnapshots = viewModel.taskSnapshots
    }

    public init(projection: TaskCenterProjection) {
        let viewModel = TaskCenterViewModel(projection: projection)
        self.viewModel = viewModel
        self.taskSnapshots = viewModel.taskSnapshots
    }

    public init(viewModel: TaskCenterViewModel) {
        self.viewModel = viewModel
        self.taskSnapshots = viewModel.taskSnapshots
    }

    public init(taskStore: AgentTaskStore, includeArchived: Bool = false) {
        self.init(snapshots: taskStore.taskCenterSnapshots(includeArchived: includeArchived))
    }

    /// Selects only from this value's captured snapshots; it never reads or changes a store.
    /// Results are sorted by parent ID and task ID to make replay independent of input order.
    /// Invalid filters fail closed and return no task facts.
    public func selecting(_ filter: TaskCenterObservationFilter) -> [AgentTaskSnapshot] {
        guard filter.isValid else { return [] }

        return taskSnapshots
            .filter { snapshot in
                matches(snapshot.taskID, allowed: filter.taskIDs)
                    && matches(snapshot.parentID, allowed: filter.parentIDs)
                    && matches(snapshot.status, allowed: filter.statuses)
                    && matches(snapshot.providerID, allowed: filter.providerIDs)
                    && matches(snapshot.modelID, allowed: filter.modelIDs)
                    && matches(snapshot.routeReceiptID, allowed: filter.routeReceiptIDs)
                    && matches(snapshot.sourceSessionID, allowed: filter.sourceSessionIDs)
                    && (filter.includeArchived || !snapshot.isArchived)
            }
            .sorted { lhs, rhs in
                if lhs.parentID != rhs.parentID { return lhs.parentID < rhs.parentID }
                return lhs.taskID < rhs.taskID
            }
    }

    private func matches<Value: Equatable>(_ value: Value, allowed: [Value]?) -> Bool {
        allowed.map { $0.contains(value) } ?? true
    }

    private func matches(_ value: String?, allowed: [String]?) -> Bool {
        guard let allowed else { return true }
        guard let value else { return false }
        return allowed.contains(value)
    }
}
