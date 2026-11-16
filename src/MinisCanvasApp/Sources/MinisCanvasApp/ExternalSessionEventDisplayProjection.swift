import Foundation
import SwiftUI
import MinisCore

/// Ephemeral display of completed, redacted external message chunks. The
/// runtime checkpoint remains the sole durable event fact; this buffer never
/// writes a transcript, receipt, log, export, or backup.
@MainActor
final class ExternalSessionEventDisplayProjection: ObservableObject {
    struct Chunk: Identifiable, Equatable {
        let id: String
        let text: String
    }

    @Published private(set) var chunks: [Chunk] = []
    private(set) var sourceID: ExternalSessionSourceID?
    private(set) var threadID: ExternalSessionThreadID?
    private var generation: UInt64?
    private var grant: ExternalSessionReadGrantV1?
    private var subscriptionID: UUID?

    @discardableResult
    func begin(
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        generation: UInt64,
        grant: ExternalSessionReadGrantV1
    ) -> UUID {
        let id = UUID()
        self.sourceID = sourceID
        self.threadID = threadID
        self.generation = generation
        self.grant = grant
        subscriptionID = id
        chunks = []
        return id
    }

    func reset() {
        subscriptionID = nil
        sourceID = nil
        threadID = nil
        generation = nil
        grant = nil
        chunks = []
    }

    func reset(ifSource sourceID: ExternalSessionSourceID) {
        if self.sourceID == sourceID { reset() }
    }

    func reset(ifSubscription id: UUID) {
        if subscriptionID == id { reset() }
    }

    func reconcileAuthorization(_ snapshot: ExternalSessionAuthorizationSnapshotV1) {
        guard let grant, isActive(grant, in: snapshot, now: .now) else {
            reset()
            return
        }
    }

    func consumer(
        composition: ExternalSessionAuthorizationComposition,
        subscriptionID id: UUID
    ) -> @Sendable (ExternalSessionEventV1) -> Void {
        { [weak self, weak composition] event in
            // High-frequency raw delta frames are progress-only. Only the
            // adapter's completed and redacted chunks enter the UI queue.
            guard event.kind == .itemDelta else { return }
            Task { @MainActor in
                guard let self, let composition,
                      self.subscriptionID == id,
                      let grant = self.grant else { return }
                // The producer checked admission and post-await delivery.
                // Recheck after the actor hop: a queued callback cannot
                // display text after revocation or expiration.
                let snapshot = await composition.authorizationSnapshot()
                guard self.subscriptionID == id else { return }
                guard self.isActive(grant, in: snapshot, now: .now) else {
                    self.reset(ifSubscription: id)
                    return
                }
                self.accept(event, subscriptionID: id)
            }
        }
    }

    private func isActive(
        _ grant: ExternalSessionReadGrantV1,
        in snapshot: ExternalSessionAuthorizationSnapshotV1,
        now: Date
    ) -> Bool {
        guard let sourceID, let threadID,
              grant.sourceID == sourceID,
              snapshot.readGrants.contains(grant),
              let epoch = snapshot.currentEpoch(sourceID: grant.sourceID, profileID: grant.profileID),
              epoch == grant.revocationEpoch,
              grant.issuedAt <= now, now < grant.expiresAt,
              grant.scopes.contains(.events) else { return false }
        switch grant.target {
        case .source(let target): return target == sourceID
        case .thread(let target): return target == threadID
        case .project: return true // Producer verifies live thread membership.
        }
    }

    private func accept(_ event: ExternalSessionEventV1, subscriptionID id: UUID) {
        guard subscriptionID == id,
              event.sourceID == sourceID,
              event.threadID == threadID,
              let generation,
              event.sourceCursor.rawValue.hasPrefix("local-notification:\(generation):"),
              event.kind == .itemDelta,
              event.payload.kind.hasPrefix("item/agentMessage/delta"),
              !chunks.contains(where: { $0.id == event.eventID.rawValue }) else { return }
        let safeText = ContentSecretRedactor.redact(event.payload.summary)
        guard !safeText.isEmpty else { return }
        let row = Chunk(id: event.eventID.rawValue, text: String(safeText.prefix(512)))
        chunks.append(row)
        if chunks.count > 32 { chunks.removeFirst(chunks.count - 32) }
    }
}
