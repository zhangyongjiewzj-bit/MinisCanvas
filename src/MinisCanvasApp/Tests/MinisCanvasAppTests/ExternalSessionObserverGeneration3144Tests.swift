import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct ObserverGenerationProbe3144: ExistingAgentSessionAdapter, Sendable {
    let source: ExternalSessionSourceV1

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        ExternalSessionReadPageV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turns: [],
            events: [],
            observedCursor: request.cursor
        )
    }

    func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        return ExternalSessionStatusV1(
            sourceID: source.sourceID,
            threadID: target.threadID,
            turnID: target.turnID,
            threadStatus: .active,
            observedCursor: .beginning,
            latestSequence: 0
        )
    }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        ExternalSessionControlReceiptV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .completed,
            sourceCursor: request.expectedCursor
        )
    }
}

private final class ObserverInterleave3144: @unchecked Sendable {
    private let lock = NSLock()
    private var didRebind = false
    private var deliveryCount = 0

    func claimRebind() -> Bool {
        lock.withLock {
            guard !didRebind else { return false }
            didRebind = true
            return true
        }
    }
    var rebound: Bool { lock.withLock { didRebind } }
    func recordDelivery() { lock.withLock { deliveryCount += 1 } }
    var deliveries: Int { lock.withLock { deliveryCount } }
}

private func observerAdapter3144(_ suffix: String) -> ExternalSessionAppAdapter {
    let source = ExternalSessionSourceV1(
        sourceID: ExternalSessionSourceID(rawValue: "observer-source-" + suffix),
        kind: .codex, adapterVersion: "owned/3144",
        profileID: ExternalSessionProfileID(rawValue: "observer-profile-" + suffix),
        hostID: "owned-memory-only", capabilities: [.status], authState: .authorized
    )
    return ExternalSessionAppAdapter(implementation: ObserverGenerationProbe3144(source: source))
}

@Suite("Actual runtime observer generation 3144")
struct ExternalSessionObserverGeneration3144Tests {
    @Test func copiedOldPublisherCannotOverwriteReboundTaskCenter() {
        // Real legal subscriptions place a rebind between the publisher's copied
        // callback array and its old Task Center callback. Dictionary order is
        // unspecified: only an observed interleave qualifies the assertion.
        // All callbacks execute through actual markOrphaned -> Ledger.publish;
        // this test never obtains or directly invokes the Task Center closure.
        var observedInterleave = false
        for attempt in 0..<64 {
            let old = observerAdapter3144("old-\(attempt)")
            let next = observerAdapter3144("next-\(attempt)")
            let consumer = TaskCenterControlConsumer(store: AgentTaskStore())
            let oldInitial = old.runtimeSnapshot
            let nextInitial = next.runtimeSnapshot
            #expect(oldInitial.ownerID != nextInitial.ownerID)
            let control = ObserverInterleave3144()
            var blockers: [ExternalSessionRuntimeObservation] = []
            for _ in 0..<32 {
                blockers.append(old.observeRuntime { snapshot in
                    guard snapshot.state == .orphaned,
                          consumer.externalSessionRuntime?.snapshot == oldInitial,
                          control.claimRebind() else { return }
                    // Legal reentrant subscription: publisher released its lock.
                    // Cancelling the previous token cannot retract its copied callback.
                    consumer.bindExternalSessionRuntime(from: next)
                })
            }
            consumer.bindExternalSessionRuntime(from: old)
            #expect(consumer.externalSessionRuntime?.snapshot == oldInitial)
            old.markOrphaned()
            if control.rebound {
                observedInterleave = true
                print("ACTUAL_OBJECT_3144 qualifying_interleave=true attempt=\(attempt) new_binding_preserved=\(consumer.externalSessionRuntime?.snapshot == nextInitial)")
                #expect(consumer.externalSessionRuntime?.snapshot == nextInitial)
                next.markOrphaned()
                #expect(consumer.externalSessionRuntime?.snapshot == next.runtimeSnapshot)
                let third = observerAdapter3144("third-\(attempt)")
                consumer.bindExternalSessionRuntime(from: third)
                #expect(consumer.externalSessionRuntime?.snapshot == third.runtimeSnapshot)
            }
            blockers.forEach { $0.cancel() }
            if observedInterleave { break }
        }
        #expect(observedInterleave, "No qualifying callback order: do not treat this run as coverage")
    }

    @Test func cancelledObservationStopsFuturePublicationWithoutChangingRuntime() {
        let adapter = observerAdapter3144("cancel")
        let control = ObserverInterleave3144()
        let before = adapter.runtimeSnapshot
        let token = adapter.observeRuntime { _ in control.recordDelivery() }
        #expect(control.deliveries == 1)
        token.cancel()
        token.cancel()
        #expect(adapter.runtimeSnapshot == before)
        adapter.markOrphaned()
        #expect(control.deliveries == 1)
        #expect(adapter.runtimeSnapshot.state == .orphaned)
    }
}
