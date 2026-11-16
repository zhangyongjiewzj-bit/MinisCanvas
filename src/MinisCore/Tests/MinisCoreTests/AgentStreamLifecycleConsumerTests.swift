import Foundation
import Testing
@testable import MinisCore

@Suite("Agent stream lifecycle consumer")
struct AgentStreamLifecycleConsumerTests {
    private func snapshot() -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(
            sessionID: "session-stream",
            providerID: "provider-stream",
            modelID: "model-stream",
            configurationFingerprint: "configuration-stream",
            skillIdentifiers: ["browser"],
            conversationID: "session-stream"
        )
    }

    private func identity() -> AgentExecutionIdentity {
        AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "session-stream",
                turnID: 21,
                messageID: "message-stream-consumer"
            ),
            operationID: "operation-stream-consumer",
            attempt: 0
        )
    }

    private func persistenceURL() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscore-stream-consumer-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("turns.json"))
    }

    @Test func cancelRejectsLateDeltaAndRestartCannotResumeImplicitly() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity()
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)
        let consumer = AgentStreamLifecycleConsumer(
            store: store,
            identity: turn,
            snapshot: context
        )

        #expect(try consumer.begin())
        #expect(try consumer.admitDelta(sequence: 1))
        #expect(try consumer.cancel())
        #expect(consumer.currentPhase == .cancelled)
        #expect(consumer.terminalTruth?.outcome == .cancelled)
        #expect(consumer.terminalTruth?.matches(identity: turn, generation: 0) == true)
        #expect(try consumer.admitDelta(sequence: 2) == false)

        let restartedStore = try AgentTurnContextStore(persistenceURL: url)
        let restarted = AgentStreamLifecycleConsumer(
            store: restartedStore,
            identity: turn,
            snapshot: context
        )
        #expect(try restarted.begin() == false)
        #expect(try restarted.admitDelta(sequence: 3) == false)
    }

    @Test func recoveryRequiresExplicitNewGenerationAndResetsSequence() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity()
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)
        let consumer = AgentStreamLifecycleConsumer(
            store: store,
            identity: turn,
            snapshot: context,
            generation: 3
        )

        #expect(try consumer.begin())
        #expect(try consumer.admitDelta(sequence: 8))
        #expect(try consumer.recoverAfterInterruption())
        #expect(consumer.currentPhase == .needsUserReview)
        #expect(try consumer.resume(generation: 3) == false)
        #expect(try consumer.resume(generation: 4))
        #expect(consumer.currentGeneration == 4)
        #expect(try consumer.admitDelta(sequence: 1))
        #expect(try consumer.admitDelta(sequence: 1) == false)
        #expect(store.record(for: turn)?.generation == 4)
        #expect(store.record(for: turn)?.streamSequence == 1)
    }

    @Test func finishRequiresWritebackAdmissionAndPersistsTerminalState() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity()
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)
        let consumer = AgentStreamLifecycleConsumer(
            store: store,
            identity: turn,
            snapshot: context
        )

        #expect(try consumer.begin())
        #expect(try consumer.admitDelta(sequence: 1))
        #expect(try consumer.finishAfterWriteback())
        #expect(consumer.currentPhase == .completed)
        #expect(try consumer.admitDelta(sequence: 2) == false)
        #expect(store.record(for: turn)?.status == .completed)
        let restartedStore = try AgentTurnContextStore(persistenceURL: url)
        #expect(restartedStore.record(for: turn)?.status == .completed)
        #expect(restartedStore.record(for: turn)?.terminalTruth?.outcome == .succeeded)
        #expect(consumer.terminalTruth?.outcome == .succeeded)
        #expect(consumer.terminalTruth?.isSuccess == true)
    }

    @Test func planStreamFinishAfterWritebackPersistsDryRunAndRejectsSuccess() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity()
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)
        let consumer = AgentStreamLifecycleConsumer(store: store, identity: turn, snapshot: context)

        #expect(try consumer.begin())
        #expect(try consumer.admitDelta(sequence: 1))
        #expect(try consumer.finishDryRunAfterWriteback(reason: "composer-plan"))
        #expect(consumer.currentPhase == .dryRun)
        #expect(consumer.terminalTruth?.outcome == .dryRun)
        #expect(consumer.terminalTruth?.reason == "composer-plan")
        #expect(store.record(for: turn)?.status == .dryRun)
        #expect(try consumer.finishAfterWriteback() == false)

        let restartedStore = try AgentTurnContextStore(persistenceURL: url)
        let restarted = AgentStreamLifecycleConsumer(
            store: restartedStore,
            identity: turn,
            snapshot: context
        )
        #expect(restarted.currentPhase == .dryRun)
        #expect(restarted.terminalTruth?.outcome == .dryRun)
        #expect(restarted.terminalTruth?.reason == "composer-plan")
        #expect(try restarted.begin() == false)
    }

    @Test func policyRefusalAndDryRunAreTerminalAndCannotBegin() throws {
        let (refusedDirectory, refusedURL) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: refusedDirectory) }
        let refusedIdentity = identity()
        let refusedSnapshot = snapshot()
        let refused = AgentStreamLifecycleConsumer(
            store: try AgentTurnContextStore(persistenceURL: refusedURL),
            identity: refusedIdentity,
            snapshot: refusedSnapshot
        )
        #expect(refused.refuseByPolicy(reason: "policy-denied"))
        #expect(refused.currentPhase == .rejected)
        #expect(refused.terminalTruth?.outcome == .policyRefused)
        #expect(try refused.begin() == false)
        #expect(refused.terminalTruth?.isSuccess == false)
        let refusedRestart = AgentStreamLifecycleConsumer(
            store: try AgentTurnContextStore(persistenceURL: refusedURL),
            identity: refusedIdentity,
            snapshot: refusedSnapshot
        )
        #expect(refusedRestart.currentPhase == .rejected)
        #expect(refusedRestart.terminalTruth?.outcome == .policyRefused)
        #expect(refusedRestart.terminalTruth?.reason == "policy-denied")
        #expect(try refusedRestart.begin() == false)

        let (dryRunDirectory, dryRunURL) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: dryRunDirectory) }
        let dryRunIdentity = identity()
        let dryRunSnapshot = snapshot()
        let dryRun = AgentStreamLifecycleConsumer(
            store: try AgentTurnContextStore(persistenceURL: dryRunURL),
            identity: dryRunIdentity,
            snapshot: dryRunSnapshot
        )
        #expect(dryRun.completeDryRun(reason: "preview-only"))
        #expect(dryRun.currentPhase == .dryRun)
        #expect(dryRun.terminalTruth?.outcome == .dryRun)
        #expect(try dryRun.begin() == false)
        let dryRunRestart = AgentStreamLifecycleConsumer(
            store: try AgentTurnContextStore(persistenceURL: dryRunURL),
            identity: dryRunIdentity,
            snapshot: dryRunSnapshot
        )
        #expect(dryRunRestart.currentPhase == .dryRun)
        #expect(dryRunRestart.terminalTruth?.outcome == .dryRun)
        #expect(dryRunRestart.terminalTruth?.reason == "preview-only")
        #expect(try dryRunRestart.begin() == false)
    }

    @Test func executionFailureIsDurableAndBlocksSuccessProjection() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity()
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)
        let consumer = AgentStreamLifecycleConsumer(store: store, identity: turn, snapshot: context)

        #expect(try consumer.begin())
        #expect(try consumer.fail(reason: "provider-failed"))
        #expect(consumer.currentPhase == .failed)
        #expect(consumer.terminalTruth?.outcome == .executionFailed)
        #expect(consumer.terminalTruth?.isSuccess == false)
        #expect(store.record(for: turn)?.status == .failed)
        #expect(store.record(for: turn)?.terminalTruth?.reason == "provider-failed")
        let restarted = AgentStreamLifecycleConsumer(
            store: try AgentTurnContextStore(persistenceURL: url),
            identity: turn,
            snapshot: context
        )
        #expect(restarted.currentPhase == .failed)
        #expect(restarted.terminalTruth?.outcome == .executionFailed)
        #expect(restarted.terminalTruth?.reason == "provider-failed")
        #expect(try consumer.finishAfterWriteback() == false)
    }
}
