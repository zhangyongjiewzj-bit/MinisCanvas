import Foundation

/// Immutable, replayable task-center view derived from task snapshots.
public struct TaskCenterProjection: Sendable, Equatable, Codable {
    public struct Counts: Sendable, Equatable, Codable {
        public let queued: Int
        public let running: Int
        public let succeeded: Int
        public let failed: Int
        public let cancelled: Int
        public let total: Int

        fileprivate init(snapshots: [AgentTaskSnapshot]) {
            var queued = 0
            var running = 0
            var succeeded = 0
            var failed = 0
            var cancelled = 0

            for snapshot in snapshots {
                switch snapshot.status {
                case .queued: queued += 1
                case .running: running += 1
                case .succeeded: succeeded += 1
                case .failed: failed += 1
                case .cancelled: cancelled += 1
                }
            }

            self.queued = queued
            self.running = running
            self.succeeded = succeeded
            self.failed = failed
            self.cancelled = cancelled
            self.total = snapshots.count
        }
    }

    public struct RouteBinding: Sendable, Equatable, Hashable, Codable {
        public let providerID: String
        public let modelID: String?
        public let routeReceiptID: String?

        public init(providerID: String, modelID: String?, routeReceiptID: String?) {
            self.providerID = providerID
            self.modelID = modelID
            self.routeReceiptID = routeReceiptID
        }
    }

    public let counts: Counts
    public let totalTasks: Int
    public let bindings: [RouteBinding]

    public init(snapshots: [AgentTaskSnapshot]) {
        counts = Counts(snapshots: snapshots)
        totalTasks = snapshots.count

        var uniqueBindings = Set<RouteBinding>()
        for snapshot in snapshots {
            guard let providerID = snapshot.providerID, !providerID.isEmpty else { continue }
            uniqueBindings.insert(RouteBinding(
                providerID: providerID,
                modelID: snapshot.modelID,
                routeReceiptID: snapshot.routeReceiptID
            ))
        }
        bindings = uniqueBindings.sorted { lhs, rhs in
            if lhs.providerID != rhs.providerID { return lhs.providerID < rhs.providerID }
            if lhs.modelID != rhs.modelID { return Self.optionalLess(lhs.modelID, rhs.modelID) }
            return Self.optionalLess(lhs.routeReceiptID, rhs.routeReceiptID)
        }
    }

    private static func optionalLess(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return left < right
        case (nil, .some): return true
        default: return false
        }
    }
}
