import Foundation
import Darwin
import MinisCore

/// The production governor's durable facts, scoped to its composition root.
/// Reopening this journal supplies a snapshot, never a permission or live call.
final class ChildGovernorCheckpointJournal2957: @unchecked Sendable {
    enum Failure: Error, Equatable { case invalidJournal, staleWriter, unavailable }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let directoryIdentity: String
        let checkpoint: ChildConcurrencyCheckpoint
    }

    private let url: URL
    private let directoryIdentity: String
    private let lock = NSLock()
    private var baseline: Data?
    private(set) var recoveredCheckpoint: ChildConcurrencyCheckpoint?

    init(directory: URL) throws {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        directoryIdentity = canonical.path
        url = canonical.appendingPathComponent("child-concurrency-checkpoint-v1.json")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try withFileLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1,
                  envelope.directoryIdentity == directoryIdentity,
                  envelope.checkpoint.globalActive >= 0,
                  envelope.checkpoint.perSessionActive.values.allSatisfy({ $0 >= 0 }),
                  envelope.checkpoint.globalActive == envelope.checkpoint.perSessionActive.values.reduce(0, +),
                  envelope.checkpoint.timestamp.isFinite else { throw Failure.invalidJournal }
            let requests = envelope.checkpoint.queuedRequests + envelope.checkpoint.activeRequests
                + envelope.checkpoint.recoveredQueuedRequests + envelope.checkpoint.unconfirmedRequests
            guard Set(requests.map(\.requestID)).count == requests.count,
                  requests.allSatisfy({ request in
                      !request.requestID.isEmpty && !request.sessionID.isEmpty && request.arrival.isFinite
                          && (request.intent.map { intent in
                              intent.parent.isValid && !intent.intentID.isEmpty && !intent.taskID.isEmpty
                                  && ((intent.runID == nil) == (intent.attemptID == nil))
                          } ?? true)
                  }) else { throw Failure.invalidJournal }
            baseline = data
            recoveredCheckpoint = envelope.checkpoint
        }
    }

    func write(_ checkpoint: ChildConcurrencyCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        try withFileLock {
            let current: Data?
            if FileManager.default.fileExists(atPath: url.path) {
                current = try Data(contentsOf: url)
            } else {
                current = nil
            }
            guard current == baseline else { throw Failure.staleWriter }
            let data = try JSONEncoder().encode(Envelope(
                schemaVersion: 1, directoryIdentity: directoryIdentity, checkpoint: checkpoint))
            try data.write(to: url, options: .atomic)
            baseline = data
        }
    }

    /// The producer journal may have committed a fresh queued intent before
    /// this governor journal was updated. Follow its validated unique lineage
    /// without inventing a waiter or reviving any admitted request.
    static func reconciledForReopen(_ checkpoint: ChildConcurrencyCheckpoint,
                                   records: [ChildLaunchIntentRecord]) throws -> ChildConcurrencyCheckpoint {
        var queued: [ChildLaunchCheckpointRequest] = []
        var unconfirmed = checkpoint.unconfirmedRequests
        for request in checkpoint.recoveredQueuedRequests + checkpoint.queuedRequests {
            guard let intent = request.intent else { queued.append(request); continue }
            guard var record = records.first(where: { $0.intent.intentID == intent.intentID }) else {
                throw Failure.invalidJournal
            }
            var visited: Set<String> = []
            while true {
                guard visited.insert(record.intent.intentID).inserted else { throw Failure.invalidJournal }
                let descendants = records.filter { $0.intent.recoveredFromIntentID == record.intent.intentID }
                guard descendants.count <= 1 else { throw Failure.invalidJournal }
                guard let descendant = descendants.first else { break }
                guard descendant.task == record.task,
                      descendant.parentBinding == record.parentBinding,
                      descendant.intent.parentContextSnapshotID == record.intent.parentContextSnapshotID,
                      descendant.intent.parent.sessionID == record.intent.parent.sessionID,
                      descendant.intent.parent.conversationID == record.intent.parent.conversationID,
                      descendant.intent.parent.actorID == record.intent.parent.actorID else {
                    throw Failure.invalidJournal
                }
                record = descendant
            }
            let recovered = ChildLaunchCheckpointRequest(requestID: record.intent.intentID,
                sessionID: request.sessionID, arrival: request.arrival,
                awaitingLocalGate: request.awaitingLocalGate, intent: record.intent, queueSequence: request.queueSequence)
            switch record.status {
            case .queued:
                if record.intent.runID == nil && record.intent.attemptID == nil {
                    queued.append(recovered)
                } else {
                    unconfirmed.append(recovered)
                }
            case .admitted: unconfirmed.append(recovered)
            case .notAdmitted: break
            }
        }
        return ChildConcurrencyCheckpoint(epoch: checkpoint.epoch,
            globalActive: checkpoint.globalActive, perSessionActive: checkpoint.perSessionActive,
            queuedSessions: [], killSwitchEngaged: checkpoint.killSwitchEngaged,
            degradedCeiling: checkpoint.degradedCeiling, timestamp: checkpoint.timestamp,
            localWaitingRequests: checkpoint.localWaitingRequests,
            queuedRequests: [], activeRequests: checkpoint.activeRequests,
            recoveredQueuedRequests: queued, unconfirmedRequests: unconfirmed)
    }

    private func withFileLock<Result>(_ body: () throws -> Result) throws -> Result {
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Failure.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
