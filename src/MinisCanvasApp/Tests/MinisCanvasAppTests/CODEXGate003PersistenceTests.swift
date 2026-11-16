import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

@Suite("GATE-003 collection restore generation")
@MainActor
struct CODEXGate003PersistenceTests {
    @Test func collectionRestoreCannotApplyAfterGraphMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate003-collection-\(UUID().uuidString)", isDirectory: true)
        let drafts = DraftStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let restoredID = UUID()
        let secondRestoredID = UUID()
        let snapshot = CanvasCollectionSnapshot(
            currentCanvasID: restoredID.uuidString,
            documents: [
                CanvasCollectionMeta(
                    id: restoredID,
                    name: "持久化画布",
                    draftKey: "canvas.\(restoredID.uuidString)"
                ),
                CanvasCollectionMeta(
                    id: secondRestoredID,
                    name: "第二个持久化画布",
                    draftKey: "canvas.\(secondRestoredID.uuidString)"
                )
            ]
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try CanvasStore.cleanupEncodedData(snapshot)
        #expect(CanvasStore.cleanupJSONIsCanonical(snapshot, data: data))
        try data.write(
            to: directory.appendingPathComponent(CanvasStore.collectionFileName),
            options: .atomic
        )

        let barrier = CollectionRestoreBarrier()
        let store = CanvasStore()
        store.collectionRestoreBeforeApplyHook = {
            await barrier.enterAndWait()
        }
        store.attachDraftStore(drafts)
        let restoreTask = try #require(store.collectionRestoreTask)
        let completionObserver = Task {
            await restoreTask.value
            await barrier.restoreFinished()
        }

        let entered = await barrier.waitUntilEntered()
        let editedNode = entered ? store.addNode(ofType: "text") : nil
        await barrier.release()
        await restoreTask.value
        await completionObserver.value

        try #require(entered, "集合恢复提前结束，未进入 apply 前屏障：\(String(describing: store.collectionRestoreDiagnostic))")
        let node = try #require(editedNode)

        #expect(store.currentCanvasID != restoredID)
        #expect(store.canvasDocuments.count == 1)
        #expect(store.graph.node(id: node.id) != nil)
    }

    @Test func rejectedCollectionDoesNotStrandApplyBarrier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate003-rejected-\(UUID().uuidString)", isDirectory: true)
        let drafts = DraftStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        // A collection marker is reserved for multiple canvases. Rejection
        // must complete the test's wait even though the apply hook never runs.
        let snapshot = CanvasCollectionSnapshot(
            currentCanvasID: id.uuidString,
            documents: [CanvasCollectionMeta(
                id: id, name: "无效单项集合", draftKey: "canvas.\(id.uuidString)"
            )]
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try CanvasStore.cleanupEncodedData(snapshot).write(
            to: directory.appendingPathComponent(CanvasStore.collectionFileName),
            options: .atomic
        )
        let barrier = CollectionRestoreBarrier()
        let store = CanvasStore()
        store.collectionRestoreBeforeApplyHook = { await barrier.enterAndWait() }
        store.attachDraftStore(drafts)
        let restoreTask = try #require(store.collectionRestoreTask)
        let completionObserver = Task {
            await restoreTask.value
            await barrier.restoreFinished()
        }
        let entered = await barrier.waitUntilEntered()
        await barrier.release()
        await restoreTask.value
        await completionObserver.value
        #expect(!entered)
        #expect(store.collectionRestoreDiagnostic == .corruptCollection)
        #expect(store.currentCanvasID != id)
    }
}

private actor CollectionRestoreBarrier {
    private var entered = false
    private var released = false
    private var finished = false
    private var entryWaiter: CheckedContinuation<Bool, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async -> Bool {
        if entered { return true }
        if finished { return false }
        return await withCheckedContinuation { continuation in
            entryWaiter = continuation
        }
    }

    func restoreFinished() {
        finished = true
        if !entered {
            entryWaiter?.resume(returning: false)
            entryWaiter = nil
        }
    }

    func enterAndWait() async {
        entered = true
        entryWaiter?.resume(returning: true)
        entryWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
