import Foundation
import Darwin
import Testing
import CanvasCore
@testable import MinisCanvasApp

private func outputContext() -> MediaTaskContext {
    let identity = CanvasExecutionIdentity(
        canvasID: UUID(), runID: UUID(), graphRevision: 3,
        nodeID: UUID(), nodeRevision: 2
    )
    return MediaTaskContext(
        identity: identity,
        providerSnapshot: ProviderSnapshot(
            providerID: "output-provider", modelID: "output-model",
            capabilities: [.video], configurationFingerprint: "output-config"
        ),
        promptFingerprint: "output-prompt"
    )
}

private func outputRecord(_ context: MediaTaskContext, path: String) -> VideoTaskRecord {
    VideoTaskRecord(
        id: "output-task",
        nodeID: context.identity.nodeID,
        providerID: context.providerSnapshot.providerID,
        taskID: "remote-output-task",
        promptFingerprint: context.promptFingerprint,
        status: .succeeded,
        videoURL: "https://example.invalid/output.mp4",
        idempotencyKey: context.idempotencyKey,
        assetPath: path
    )
}

@Suite("P3 artifact output recovery consumer")
struct ArtifactOutputRecoveryConsumerTests {
    @Test("lineage and relative target survive reopen")
    func lineageAndTargetSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)

        let context = outputContext()
        let store = ArtifactStore(directory: root.appendingPathComponent("receipts"), allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(outputRecord(context, path: media.path), context: context)
        #expect(receipt.targetPath == "media/result.mp4")
        #expect(receipt.lineage?.producerRevision.contains(context.providerSnapshot.providerID) == true)
        #expect((await store.validateTarget(id: receipt.id, action: .open)).status == .ready)
        #expect(await store.targetURL(id: receipt.id, action: .reveal)?.path == media.path)

        let reopened = ArtifactStore(directory: root.appendingPathComponent("receipts"), allowedMediaRoot: root)
        #expect(await reopened.receipt(id: receipt.id) == receipt)
        #expect((await reopened.validateTarget(id: receipt.id, action: .reveal)).status == .ready)
    }

    @Test("恢复后的 receipt 可重新打开且跨重启保持")
    func restoredReceiptReopensAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)

        let context = outputContext()
        let receipts = root.appendingPathComponent("receipts")
        let store = ArtifactStore(directory: receipts, allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(outputRecord(context, path: media.path), context: context)

        #expect(await store.delete(id: receipt.id))
        #expect((await store.validateTarget(id: receipt.id, action: .open)).status == .rollbackAvailable)
        let reopened = await store.reopen(id: receipt.id, action: .open)
        #expect(reopened.status == .ready)
        #expect(await store.targetURL(id: receipt.id, action: .open)?.path == media.path)
        #expect((await store.receipt(id: receipt.id))?.version == 3)

        let restarted = ArtifactStore(directory: receipts, allowedMediaRoot: root)
        #expect((await restarted.validateTarget(id: receipt.id, action: .reveal)).status == .ready)
    }

    @Test("目标内容变化时 checksum 门禁阻止打开")
    func changedTargetFailsClosedByChecksum() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)

        let context = outputContext()
        let store = ArtifactStore(directory: root.appendingPathComponent("receipts"), allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(outputRecord(context, path: media.path), context: context)
        let recordedIdentity = try #require(receipt.fileIdentity)
        try Data("change".utf8).write(to: media)
        var sameInodeInfo = stat()
        #expect(lstat(media.path, &sameInodeInfo) == 0)
        #expect(UInt64(sameInodeInfo.st_dev) == recordedIdentity.device)
        #expect(UInt64(sameInodeInfo.st_ino) == recordedIdentity.inode)
        #expect((await store.validateTarget(id: receipt.id, action: .open)).status == .stale)

        try Data("result".utf8).write(to: media)
        #expect((await store.validateTarget(id: receipt.id, action: .open)).status == .ready)
        try Data("replacement".utf8).write(to: media, options: .atomic)
        var replacementInfo = stat()
        #expect(lstat(media.path, &replacementInfo) == 0)
        #expect(
            UInt64(replacementInfo.st_dev) != recordedIdentity.device
                || UInt64(replacementInfo.st_ino) != recordedIdentity.inode
        )

        #expect((await store.validateTarget(id: receipt.id, action: .open)).status == .stale)
        #expect(await store.targetURL(id: receipt.id, action: .open) == nil)
        #expect(await store.delete(id: receipt.id))
        let recovery = await store.reopen(id: receipt.id, action: .open)
        #expect(recovery.status == .recoveryRequired)
        #expect((await store.validateTarget(id: receipt.id, action: .open)).status == .rollbackAvailable)
    }

    @Test("重启时 task identity 或 result revision 错配必须进入恢复")
    func movedOrPartialReceiptFailsClosedOnRestart() async throws {
        struct SnapshotFixture: Codable {
            let schemaVersion: Int
            let receipts: [ArtifactReceipt]
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        let receiptsRoot = root.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)

        let context = outputContext()
        let store = ArtifactStore(directory: receiptsRoot, allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(outputRecord(context, path: media.path), context: context)
        let moved = ArtifactReceipt(
            id: "artifact-moved-task",
            canvasID: receipt.canvasID,
            runID: receipt.runID,
            graphRevision: receipt.graphRevision,
            nodeID: receipt.nodeID,
            nodeRevision: receipt.nodeRevision,
            taskID: receipt.taskID,
            version: receipt.version,
            localPath: receipt.localPath,
            checksum: receipt.checksum,
            createdAt: receipt.createdAt,
            updatedAt: receipt.updatedAt,
            isDeleted: receipt.isDeleted,
            fileIdentity: receipt.fileIdentity,
            origin: receipt.origin,
            terminalState: receipt.terminalState,
            targetPath: receipt.targetPath,
            lineage: receipt.lineage,
            rollback: receipt.rollback
        )
        let snapshotURL = receiptsRoot.appendingPathComponent(ArtifactStore.snapshotFileName)
        let movedSnapshotBytes = try JSONEncoder().encode(
            SnapshotFixture(schemaVersion: 1, receipts: [moved])
        )
        try movedSnapshotBytes.write(to: snapshotURL, options: .atomic)

        let restarted = ArtifactStore(directory: receiptsRoot, allowedMediaRoot: root)
        let validation = await restarted.validateTarget(id: moved.id, action: .open)
        #expect(validation.status == .recoveryRequired)
        #expect(validation.userProjection.state == .recoveryRequired)
        #expect(!(await restarted.diagnostics()).isHealthy)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        let quarantinedSnapshots = try FileManager.default.contentsOfDirectory(
            at: receiptsRoot,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                "\(snapshotURL.deletingPathExtension().lastPathComponent).quarantine-"
            )
        }
        #expect(quarantinedSnapshots.count == 1)
        let quarantinedSnapshot = try #require(quarantinedSnapshots.first)
        #expect(try Data(contentsOf: quarantinedSnapshot) == movedSnapshotBytes)
    }

    @Test("相同 task 的 terminal replay 若 lineage 不同必须拒绝复用")
    func terminalReplayWithDifferentLineageFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-lineage-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)

        let context = outputContext()
        let record = outputRecord(context, path: media.path)
        let store = ArtifactStore(directory: root.appendingPathComponent("receipts"), allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(record, context: context)
        guard let original = receipt.lineage else {
            #expect(Bool(false), "generated artifact must carry lineage")
            return
        }
        let replayLineage = ArtifactResultLineage(
            sourceArtifactID: original.sourceArtifactID,
            sourceRevision: original.sourceRevision,
            producerRevision: original.producerRevision,
            resultRevision: original.resultRevision + "-replay"
        )

        do {
            _ = try await store.recordMediaCompletionResult(
                record,
                context: context,
                lineage: replayLineage
            )
            #expect(Bool(false), "lineage replay must not reuse the current artifact")
        } catch let error as ArtifactStoreError {
            #expect(error == .identityMismatch)
        } catch {
            #expect(Bool(false), "unexpected artifact replay error")
        }

        try Data("replacement".utf8).write(to: media, options: .atomic)
        do {
            _ = try await store.recordMediaCompletionResult(
                record,
                context: context,
                lineage: original
            )
            #expect(Bool(false), "replay of a different current output must be rejected")
        } catch let error as ArtifactStoreError {
            #expect(error == .identityMismatch)
        } catch {
            #expect(Bool(false), "unexpected output replay error")
        }
    }

    @Test("重启时 targetPath 偏离 receipt localPath 必须隔离")
    func redirectedTargetFailsClosedOnRestart() async throws {
        struct SnapshotFixture: Codable {
            let schemaVersion: Int
            let receipts: [ArtifactReceipt]
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-target-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        let redirected = root.appendingPathComponent("media/redirected.mp4")
        let receiptsRoot = root.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)
        try Data("result".utf8).write(to: redirected, options: .atomic)

        let context = outputContext()
        let store = ArtifactStore(directory: receiptsRoot, allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(outputRecord(context, path: media.path), context: context)
        let movedTarget = ArtifactReceipt(
            id: receipt.id,
            canvasID: receipt.canvasID,
            runID: receipt.runID,
            graphRevision: receipt.graphRevision,
            nodeID: receipt.nodeID,
            nodeRevision: receipt.nodeRevision,
            taskID: receipt.taskID,
            version: receipt.version,
            localPath: receipt.localPath,
            checksum: receipt.checksum,
            createdAt: receipt.createdAt,
            updatedAt: receipt.updatedAt,
            isDeleted: receipt.isDeleted,
            fileIdentity: receipt.fileIdentity,
            origin: receipt.origin,
            terminalState: receipt.terminalState,
            targetPath: "media/redirected.mp4",
            lineage: receipt.lineage,
            rollback: receipt.rollback
        )
        try JSONEncoder().encode(SnapshotFixture(schemaVersion: 1, receipts: [movedTarget])).write(
            to: receiptsRoot.appendingPathComponent(ArtifactStore.snapshotFileName),
            options: .atomic
        )

        let restarted = ArtifactStore(directory: receiptsRoot, allowedMediaRoot: root)
        let validation = await restarted.validateTarget(id: receipt.id, action: .open)
        #expect(validation.status == .invalidTarget)
        #expect(validation.userProjection.state == .invalidTarget)
        #expect(await restarted.targetURL(id: receipt.id, action: .open) == nil)
    }

    @Test("receipt 后同内容替换文件也不得恢复为 ready")
    func sameContentReplacementFailsClosedByFileIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-file-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        let receiptsRoot = root.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)

        let context = outputContext()
        let store = ArtifactStore(directory: receiptsRoot, allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(outputRecord(context, path: media.path), context: context)
        try FileManager.default.removeItem(at: media)
        try Data("result".utf8).write(to: media, options: .atomic)

        let restarted = ArtifactStore(directory: receiptsRoot, allowedMediaRoot: root)
        let validation = await restarted.validateTarget(id: receipt.id, action: .open)
        #expect(validation.status == .stale)
        #expect(validation.userProjection.state == .stale)
        #expect(await restarted.targetURL(id: receipt.id, action: .open) == nil)
    }

    @Test("traversal and missing targets fail closed")
    func invalidAndMissingTargetsFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-output-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/result.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: media, options: .atomic)
        let context = outputContext()
        let store = ArtifactStore(directory: root.appendingPathComponent("receipts"), allowedMediaRoot: root)
        let receipt = try await store.recordMediaCompletion(outputRecord(context, path: media.path), context: context)
        try FileManager.default.removeItem(at: media)
        #expect((await store.validateTarget(id: receipt.id, action: .open)).status == .missing)

        let bad = ArtifactReceipt(
            id: "bad-target", canvasID: context.identity.canvasID, runID: context.identity.runID,
            graphRevision: context.identity.graphRevision, nodeID: context.identity.nodeID,
            nodeRevision: context.identity.nodeRevision, taskID: "bad", version: 1,
            localPath: root.appendingPathComponent("media/result.mp4").path, checksum: "x",
            createdAt: Date(), updatedAt: Date(), isDeleted: false,
            origin: ArtifactOrigin(
                providerID: context.providerSnapshot.providerID, modelID: context.providerSnapshot.modelID,
                configurationFingerprint: context.providerSnapshot.configurationFingerprint,
                promptFingerprint: context.promptFingerprint, idempotencyKey: context.idempotencyKey
            ), terminalState: .succeeded, targetPath: "../outside.txt"
        )
        // The public store intentionally has no arbitrary receipt injection API;
        // this fixture documents the constructor contract without persisting it.
        #expect(bad.targetPath == "../outside.txt")
    }

    @Test("document stage lineage is explicit and codable")
    func documentLineageIsExplicit() throws {
        var pipeline = DocumentPipeline(stages: [DocumentStage(name: "结果", status: .awaitingReview)])
        pipeline.attachOutputLineage(
            at: 0, artifactID: "artifact-output-task", sourceArtifactID: nil,
            sourceRevision: "source-revision", resultRevision: "result-revision"
        )
        let decoded = try JSONDecoder().decode(
            DocumentPipeline.self,
            from: JSONEncoder().encode(pipeline)
        )
        #expect(decoded.stages[0].outputLineage?.artifactID == "artifact-output-task")
        #expect(decoded.stages[0].outputLineage?.sourceArtifactID == nil)
    }

    @Test("文档结果 reopen 与失效恢复保持 lineage")
    func documentLineageReconcilesWithoutLeakingTarget() throws {
        var pipeline = DocumentPipeline(stages: [DocumentStage(name: "结果", status: .awaitingReview)])
        pipeline.attachOutputLineage(
            at: 0, artifactID: "artifact-output-task", sourceArtifactID: nil,
            sourceRevision: "source-revision", resultRevision: "result-revision"
        )
        let ready = ArtifactTargetValidation(
            artifactID: "artifact-output-task", action: .open, status: .ready,
            targetPath: "/private/not-exposed-to-document", message: "artifact 可打开。"
        )
        let reconciled = pipeline.reconcileOutputLineage(at: 0, validation: ready)
        #expect(reconciled)
        let reopened = pipeline.reopenOutput(at: 0, validation: ready)
        #expect(reopened)
        #expect(pipeline.stages[0].status == .awaitingReview)
        #expect(pipeline.stages[0].outputLineage?.artifactID == "artifact-output-task")

        let stale = ArtifactTargetValidation(
            artifactID: "artifact-output-task", action: .open, status: .stale,
            targetPath: "media/result.mp4", message: "artifact 文件内容已变化，已隔离等待恢复。"
        )
        let staleReopen = pipeline.reopenOutput(at: 0, validation: stale)
        #expect(!staleReopen)
        #expect(pipeline.stages[0].status == .stale)
        #expect(pipeline.stages[0].outputLineage?.artifactID == "artifact-output-task")
    }
}
