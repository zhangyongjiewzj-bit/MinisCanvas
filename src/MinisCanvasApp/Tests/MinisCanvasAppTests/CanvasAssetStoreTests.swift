import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

struct CanvasAssetStoreTests {
    @Test func snapshotRoundTripsAndPreservesCanvasIsolation() async throws {
        let canvasID = UUID()
        let asset = MediaAsset(kind: .image, source: .imported, localURL: "/tmp/a.png")
        let source = CanvasAssetStore()
        await source.register(asset, canvasID: canvasID)
        let data = try await source.encodedSnapshot()
        let snapshot = try JSONDecoder().decode(CanvasAssetStoreSnapshot.self, from: data)
        let restored = CanvasAssetStore(snapshot: snapshot)
        #expect(await restored.asset(id: asset.id, canvasID: canvasID) == asset)
    }

    @Test func assetsStayIsolatedByCanvas() async {
        let store = CanvasAssetStore()
        let canvasA = UUID()
        let canvasB = UUID()
        let asset = MediaAsset(kind: .image, source: .imported, localURL: "/tmp/a.png")

        await store.register(asset, canvasID: canvasA)

        #expect(await store.asset(id: asset.id, canvasID: canvasA) == asset)
        #expect(await store.asset(id: asset.id, canvasID: canvasB) == nil)
        #expect(await store.assets(canvasID: canvasB).isEmpty)
    }

    @Test func globalLookupFailsClosedForAmbiguousAssetID() async {
        let canvasA = UUID()
        let canvasB = UUID()
        let assetID = UUID()
        let assetA = MediaAsset(
            id: assetID,
            kind: .image,
            source: .imported,
            localURL: "/tmp/a.png",
            sourceCanvasID: canvasA
        )
        let assetB = MediaAsset(
            id: assetID,
            kind: .image,
            source: .imported,
            localURL: "/tmp/b.png",
            sourceCanvasID: canvasB
        )
        let store = CanvasAssetStore(snapshot: CanvasAssetStoreSnapshot(
            assetsByCanvas: [
                canvasA: [assetA],
                canvasB: [assetB],
            ]
        ))

        #expect(await store.asset(id: assetID, canvasID: canvasA) == assetA)
        #expect(await store.asset(id: assetID, canvasID: canvasB) == assetB)
        #expect(await store.asset(id: assetID) == nil)
    }

    @Test func registerRejectsAssetIDAlreadyOwnedByAnotherCanvas() async {
        let canvasA = UUID()
        let canvasB = UUID()
        let assetID = UUID()
        let assetA = MediaAsset(
            id: assetID,
            kind: .image,
            source: .imported,
            localURL: "/tmp/a.png",
            sourceCanvasID: canvasA
        )
        let assetB = MediaAsset(
            id: assetID,
            kind: .image,
            source: .imported,
            localURL: "/tmp/b.png",
            sourceCanvasID: canvasB
        )
        let store = CanvasAssetStore()

        #expect(await store.register(assetA, canvasID: canvasA))
        #expect(await store.register(assetB, canvasID: canvasB) == false)
        #expect(await store.assets(canvasID: canvasB).isEmpty)
    }

    @Test func envelopeRegistrationUsesOriginCanvasAndRejectsForeignAsset() async {
        let canvasA = UUID()
        let canvasB = UUID()
        let envelope = DAGExecutionEnvelope(
            canvasID: canvasA,
            runID: UUID(),
            graphRevision: 3,
            graphFingerprint: "graph-fp"
        )
        let store = CanvasAssetStore()
        let originAsset = MediaAsset(
            kind: .image,
            source: .imported,
            localURL: "/tmp/origin.png",
            sourceCanvasID: canvasA
        )
        let foreignAsset = MediaAsset(
            kind: .image,
            source: .imported,
            localURL: "/tmp/foreign.png",
            sourceCanvasID: canvasB
        )

        #expect(await store.register(originAsset, envelope: envelope))
        #expect(await store.asset(id: originAsset.id, canvasID: canvasA) == originAsset)
        #expect(await store.asset(id: originAsset.id, canvasID: canvasB) == nil)
        #expect(await store.register(foreignAsset, executionEnvelope: envelope) == false)
    }

    @Test func duplicateOlderVersionDoesNotOverwriteNewerAsset() async {
        let store = CanvasAssetStore()
        let canvasID = UUID()
        let id = UUID()
        let newer = MediaAsset(id: id, kind: .video, source: .generated, version: 2, metadata: ["state": "new"])
        let older = MediaAsset(id: id, kind: .video, source: .generated, version: 1, metadata: ["state": "old"])

        await store.register(newer, canvasID: canvasID)
        await store.register(older, canvasID: canvasID)

        #expect(await store.asset(id: id, canvasID: canvasID)?.metadata["state"] == "new")
    }

    @Test func removeIsTombstoneAndCanBeInspected() async {
        let store = CanvasAssetStore()
        let canvasID = UUID()
        let asset = MediaAsset(kind: .image, source: .imported)
        await store.register(asset, canvasID: canvasID)

        #expect(await store.remove(assetID: asset.id, canvasID: canvasID))
        #expect(await store.assets(canvasID: canvasID).isEmpty)
        #expect(await store.assets(canvasID: canvasID, includingDeleted: true).first?.status == .deleted)
    }

    @Test @MainActor
    func restoreSnapshotMergesDuplicateProjectionIDsDeterministically() async {
        let store = CanvasStore()
        let canvasA = UUID()
        let canvasB = UUID()
        let assetID = UUID()
        let older = MediaAsset(
            id: assetID,
            kind: .image,
            source: .imported,
            localURL: "/tmp/older.png",
            sourceCanvasID: canvasA,
            version: 1,
            metadata: ["marker": "older"]
        )
        let newer = MediaAsset(
            id: assetID,
            kind: .image,
            source: .imported,
            localURL: "/tmp/newer.png",
            sourceCanvasID: canvasB,
            version: 2,
            metadata: ["marker": "newer"]
        )

        store.restoreAssetSnapshot(
            CanvasAssetStoreSnapshot(
                assetsByCanvas: [
                    canvasA: [older],
                    canvasB: [newer],
                ]
            )
        )
        await Task.yield()

        #expect(await store.assetStore.asset(id: assetID, canvasID: canvasA) == older)
        #expect(await store.assetStore.asset(id: assetID, canvasID: canvasB) == newer)
    }
}
