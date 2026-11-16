import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 CanvasAssetStore 幂等写回")
struct P3AuditMediaAssetIdempotencyTests {
    @Test func duplicateSuccessfulWritebackIsRejectedWithoutVersionMutation() async {
        let identity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 4,
            nodeID: UUID(),
            nodeRevision: 2
        )
        let context = MediaTaskContext(
            identity: identity,
            providerSnapshot: ProviderSnapshot(
                providerID: "p3-provider",
                modelID: "video-v1",
                capabilities: [.video],
                configurationFingerprint: "config-fp"
            ),
            promptFingerprint: "prompt-fp"
        )
        let record = VideoTaskRecord(
            id: "p3-duplicate-record",
            nodeID: identity.nodeID,
            providerID: context.providerSnapshot.providerID,
            taskID: "remote-p3-duplicate",
            promptFingerprint: context.promptFingerprint,
            status: .succeeded,
            videoURL: "https://cdn.example/p3-duplicate.mp4",
            idempotencyKey: context.idempotencyKey,
            assetPath: "/tmp/p3-duplicate.mp4"
        )
        let store = CanvasAssetStore()

        #expect(await store.registerVideoTaskResult(
            record,
            context: context,
            currentIdentity: identity
        ) == .accepted)
        let first = await store.assets(canvasID: identity.canvasID, includingDeleted: true)
        #expect(first.count == 1)
        let firstVersion = first[0].version

        let duplicate = await store.registerVideoTaskResult(
            record,
            context: context,
            currentIdentity: identity
        )
        #expect(duplicate != .accepted)

        let afterDuplicate = await store.assets(canvasID: identity.canvasID, includingDeleted: true)
        #expect(afterDuplicate.count == 1)
        #expect(afterDuplicate[0].version == firstVersion)
    }

    @Test func sameIdempotencyIntentWithNewRecordIDIsRejected() async {
        let identity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 9,
            nodeID: UUID(),
            nodeRevision: 3
        )
        let context = MediaTaskContext(
            identity: identity,
            providerSnapshot: ProviderSnapshot(
                providerID: "p3-provider",
                modelID: "video-v1",
                capabilities: [.video],
                configurationFingerprint: "config-fp"
            ),
            promptFingerprint: "same-intent"
        )
        let first = VideoTaskRecord(
            id: "p3-record-a",
            nodeID: identity.nodeID,
            providerID: context.providerSnapshot.providerID,
            taskID: "remote-p3-a",
            promptFingerprint: context.promptFingerprint,
            status: .succeeded,
            videoURL: "https://cdn.example/p3-a.mp4",
            idempotencyKey: context.idempotencyKey,
            assetPath: "/tmp/p3-a.mp4"
        )
        let retryCallback = VideoTaskRecord(
            id: "p3-record-b",
            nodeID: identity.nodeID,
            providerID: context.providerSnapshot.providerID,
            taskID: "remote-p3-b",
            promptFingerprint: context.promptFingerprint,
            status: .succeeded,
            videoURL: "https://cdn.example/p3-b.mp4",
            idempotencyKey: context.idempotencyKey,
            assetPath: "/tmp/p3-b.mp4"
        )
        let store = CanvasAssetStore()

        #expect(await store.registerVideoTaskResult(
            first,
            context: context,
            currentIdentity: identity
        ) == .accepted)
        #expect(await store.registerVideoTaskResult(
            retryCallback,
            context: context,
            currentIdentity: identity
        ) == .rejected(.invalidPayload))
        #expect(await store.assets(canvasID: identity.canvasID).count == 1)
    }
}
