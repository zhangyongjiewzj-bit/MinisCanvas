import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private func artifactContractContext(
    canvasID: UUID = UUID(),
    runID: UUID = UUID(),
    nodeID: UUID = UUID(),
    modelID: String = "artifact-contract-model"
) -> MediaTaskContext {
    let identity = CanvasExecutionIdentity(
        canvasID: canvasID,
        runID: runID,
        graphRevision: 1,
        nodeID: nodeID,
        nodeRevision: 1
    )
    return MediaTaskContext(
        identity: identity,
        providerSnapshot: ProviderSnapshot(
            providerID: "artifact-contract-provider",
            modelID: modelID,
            capabilities: [.video],
            configurationFingerprint: "artifact-contract-config"
        ),
        promptFingerprint: "artifact-contract-prompt"
    )
}

private func artifactContractRecord(
    context: MediaTaskContext,
    assetPath: String,
    status: VideoTaskRecord.Status = .succeeded,
    id: String = "artifact-contract-task"
) -> VideoTaskRecord {
    VideoTaskRecord(
        id: id,
        nodeID: context.identity.nodeID,
        providerID: context.providerSnapshot.providerID,
        taskID: "remote-\\(id)",
        promptFingerprint: context.promptFingerprint,
        status: status,
        videoURL: "https://cdn.example/\\(id).mp4",
        idempotencyKey: context.idempotencyKey,
        assetPath: assetPath
    )
}

@Suite("Artifact result production contract")
struct ArtifactResultContractTests {
    @Test
    func productionReceiptPersistsOriginTerminalAndRecoversAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-contract-\\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let mediaURL = mediaRoot.appendingPathComponent("result.mp4")
        try Data("artifact-result".utf8).write(to: mediaURL, options: .atomic)

        let context = artifactContractContext()
        let record = artifactContractRecord(context: context, assetPath: mediaURL.path)
        let store = ArtifactStore(directory: artifactRoot, allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(record, context: context)

        #expect(receipt.terminalState == .succeeded)
        #expect(receipt.origin?.providerID == context.providerSnapshot.providerID)
        #expect(receipt.origin?.modelID == context.providerSnapshot.modelID)
        #expect(receipt.origin?.configurationFingerprint == context.providerSnapshot.configurationFingerprint)
        #expect((await store.diagnostics()).isHealthy)

        let restarted = ArtifactStore(directory: artifactRoot, allowedMediaRoot: root)
        #expect(await restarted.receipt(id: receipt.id) == receipt)
        #expect((await restarted.diagnostics()).isHealthy)
    }

    @Test
    func changedProviderOriginForSameTaskIsRejectedBeforeReuse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-origin-\\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let mediaURL = mediaRoot.appendingPathComponent("result.mp4")
        try Data("artifact-origin".utf8).write(to: mediaURL, options: .atomic)

        let context = artifactContractContext()
        let store = ArtifactStore(directory: root.appendingPathComponent("artifacts"), allowedMediaRoot: root)
        let first = artifactContractRecord(context: context, assetPath: mediaURL.path)
        _ = try await store.recordMediaCompletion(first, context: context)

        let changed = artifactContractContext(
            canvasID: context.identity.canvasID,
            runID: context.identity.runID,
            nodeID: context.identity.nodeID,
            modelID: "different-model"
        )
        let changedRecord = artifactContractRecord(
            context: changed,
            assetPath: mediaURL.path,
            id: first.id
        )
        do {
            _ = try await store.recordMediaCompletion(changedRecord, context: changed)
            Issue.record("相同任务 ID 的 provider origin 变化不得复用 receipt")
        } catch ArtifactStoreError.identityMismatch {
            // expected
        }
    }

    @Test
    func nonTerminalResultIsRejectedAndCorruptSnapshotRequiresRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-recovery-\\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let mediaURL = mediaRoot.appendingPathComponent("result.mp4")
        try Data("artifact-recovery".utf8).write(to: mediaURL, options: .atomic)

        let context = artifactContractContext()
        let store = ArtifactStore(directory: artifactRoot, allowedMediaRoot: root)
        let active = artifactContractRecord(
            context: context,
            assetPath: mediaURL.path,
            status: .polling
        )
        do {
            _ = try await store.recordMediaCompletion(active, context: context)
            Issue.record("非 terminal 任务不得投影为 artifact result")
        } catch ArtifactStoreError.invalidPayload {
            // expected
        }

        try Data("not-json".utf8).write(
            to: artifactRoot.appendingPathComponent(ArtifactStore.snapshotFileName),
            options: .atomic
        )
        let recovered = ArtifactStore(directory: artifactRoot, allowedMediaRoot: root)
        #expect(await recovered.diagnostics() == ArtifactStoreDiagnostics(
            state: .recoveryRequired,
            reason: "corrupt_snapshot"
        ))
        do {
            _ = try await recovered.recordMediaCompletion(
                artifactContractRecord(context: context, assetPath: mediaURL.path),
                context: context
            )
            Issue.record("损坏快照必须阻断生产写入")
        } catch ArtifactStoreError.recoveryRequired {
            // expected
        }
    }
}
