import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - B2 legacy asset snapshot migration (P3)
//
// Conservative policy under test:
//   legacy  = Session/DraftStore root  (<AppSupport>/MinisCanvas/canvas_assets.json)
//   current = VideoTaskStore root      (<AppSupport>/MinisCore/canvas_assets.json)
//   - current missing + legacy decodes            -> atomically copy legacy to current, retain legacy
//   - both exist + both decode                   -> merge by (canvasID, assetID): union of records and
//                                                    canvas mappings; duplicate asset ID -> current wins
//                                                    deterministically; legacy never deleted; the only
//                                                    current write is the merged union
//   - legacy invalid / current unreadable        -> leave current untouched, no destructive action
// The migration lives at the startup call-site (CanvasStore.attachDraftStore),
// NOT inside CanvasAssetStore.loadSnapshot, so the existing root assertion
// tests (CanvasAssetStoreTests) keep their exact behavior.

private func p3b2TmpRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("p3b2-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func p3b2Asset(
    id: UUID = UUID(),
    canvasID: UUID,
    version: Int = 1,
    marker: String
) -> MediaAsset {
    MediaAsset(
        id: id,
        kind: .image,
        source: .imported,
        localURL: "/tmp/\(marker).png",
        sourceCanvasID: canvasID,
        version: version,
        metadata: ["marker": marker]
    )
}

private func p3b2Snapshot(_ assetsByCanvas: [UUID: [MediaAsset]]) -> CanvasAssetStoreSnapshot {
    CanvasAssetStoreSnapshot(schemaVersion: 1, assetsByCanvas: assetsByCanvas)
}

private func p3b2SnapshotURL(in root: URL) -> URL {
    root.appendingPathComponent(CanvasAssetStore.snapshotFileName)
}

private func p3b2WriteSnapshot(_ snapshot: CanvasAssetStoreSnapshot, to root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: p3b2SnapshotURL(in: root), options: .atomic)
}

@Suite("P3 B2 legacy asset snapshot migration")
struct P3B2LegacyAssetMigrationTests {
    @Test
    func missingLegacyIsNoOpAndLeavesCurrentUntouched() async throws {
        let root = p3b2TmpRoot("no-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        try p3b2WriteSnapshot(
            p3b2Snapshot([canvasID: [p3b2Asset(canvasID: canvasID, marker: "current")]]),
            to: currentDir
        )
        let currentBefore = try Data(contentsOf: p3b2SnapshotURL(in: currentDir))

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )

        #expect(outcome == .noLegacySnapshot)
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: currentDir)) == currentBefore)
    }

    @Test
    func currentMissingCopiesLegacyAtomicallyAndRetainsLegacy() async throws {
        let root = p3b2TmpRoot("copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        let legacyAsset = p3b2Asset(canvasID: canvasID, marker: "legacy")
        try p3b2WriteSnapshot(p3b2Snapshot([canvasID: [legacyAsset]]), to: legacyDir)
        let legacyBefore = try Data(contentsOf: p3b2SnapshotURL(in: legacyDir))

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )

        #expect(outcome == .copiedLegacyToCurrent)
        // Legacy snapshot retained byte-for-byte (never deleted, never modified).
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: legacyDir)) == legacyBefore)
        // Current now decodes to the legacy asset.
        let loaded = try #require(CanvasAssetStore.loadSnapshot(from: currentDir))
        #expect(loaded.assetsByCanvas[canvasID]?.first?.metadata["marker"] == "legacy")
    }

    @Test
    func migrationIsIdempotentSecondRunWritesNothing() async throws {
        let root = p3b2TmpRoot("idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        try p3b2WriteSnapshot(
            p3b2Snapshot([canvasID: [p3b2Asset(canvasID: canvasID, marker: "legacy")]]),
            to: legacyDir
        )
        try p3b2WriteSnapshot(
            p3b2Snapshot([canvasID: [p3b2Asset(canvasID: canvasID, marker: "current")]]),
            to: currentDir
        )

        let first = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )
        #expect(first == .merged)
        let currentAfterFirst = try Data(contentsOf: p3b2SnapshotURL(in: currentDir))
        let legacyAfterFirst = try Data(contentsOf: p3b2SnapshotURL(in: legacyDir))

        let second = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )
        #expect(second == .alreadySynchronized)
        // No rewrite: current bytes and legacy bytes are untouched by the second run.
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: currentDir)) == currentAfterFirst)
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: legacyDir)) == legacyAfterFirst)
    }

    @Test
    func duplicateAssetIDCurrentWinsDeterministicallyOverHigherVersion() async throws {
        let root = p3b2TmpRoot("current-wins")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        let dupID = UUID()
        // Legacy carries a HIGHER version for the duplicate ID: current must still
        // win deterministically (policy is "current wins", not version arbitration).
        let legacyDup = p3b2Asset(id: dupID, canvasID: canvasID, version: 99, marker: "legacy-high-version")
        let currentDup = p3b2Asset(id: dupID, canvasID: canvasID, version: 1, marker: "current")
        let legacyOnly = p3b2Asset(canvasID: canvasID, marker: "legacy-only")
        let currentOnly = p3b2Asset(canvasID: canvasID, marker: "current-only")
        try p3b2WriteSnapshot(p3b2Snapshot([canvasID: [legacyDup, legacyOnly]]), to: legacyDir)
        try p3b2WriteSnapshot(p3b2Snapshot([canvasID: [currentDup, currentOnly]]), to: currentDir)

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )
        #expect(outcome == .merged)

        let merged = try #require(CanvasAssetStore.loadSnapshot(from: currentDir))
        let byID = Dictionary(uniqueKeysWithValues: (merged.assetsByCanvas[canvasID] ?? []).map { ($0.id, $0) })
        #expect(byID[dupID]?.metadata["marker"] == "current")
        #expect(byID[legacyOnly.id]?.metadata["marker"] == "legacy-only")
        #expect(byID[currentOnly.id]?.metadata["marker"] == "current-only")
        #expect(byID.count == 3)
        // Legacy retained.
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: legacyDir)).isEmpty == false)
    }

    @Test
    func orphanCanvasUnionPreservedAndLoadsWithoutCrash() async throws {
        let root = p3b2TmpRoot("orphan-canvas")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasA = UUID()
        let canvasB = UUID()
        // canvasB exists ONLY in legacy (orphan from the current snapshot's view).
        let legacyOrphan = p3b2Asset(canvasID: canvasB, marker: "legacy-orphan-canvas")
        let currentAsset = p3b2Asset(canvasID: canvasA, marker: "current")
        try p3b2WriteSnapshot(p3b2Snapshot([canvasB: [legacyOrphan]]), to: legacyDir)
        try p3b2WriteSnapshot(p3b2Snapshot([canvasA: [currentAsset]]), to: currentDir)

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )
        #expect(outcome == .merged)

        let merged = try #require(CanvasAssetStore.loadSnapshot(from: currentDir))
        // Union of canvas mappings: both canvases survive.
        #expect(Set(merged.assetsByCanvas.keys) == [canvasA, canvasB])
        // Merged snapshot loads into the canonical store without crashing.
        let restored = CanvasAssetStore(snapshot: merged)
        #expect(await restored.assets(canvasID: canvasB).map(\.id) == [legacyOrphan.id])
        #expect(await restored.assets(canvasID: canvasA).map(\.id) == [currentAsset.id])
    }

    @Test
    func invalidLegacyLeavesCurrentUntouched() async throws {
        let root = p3b2TmpRoot("invalid-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        try p3b2WriteSnapshot(
            p3b2Snapshot([canvasID: [p3b2Asset(canvasID: canvasID, marker: "current")]]),
            to: currentDir
        )
        let currentBefore = try Data(contentsOf: p3b2SnapshotURL(in: currentDir))
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: p3b2SnapshotURL(in: legacyDir))

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )

        #expect(outcome == .legacyInvalid)
        // No destructive action: current snapshot untouched, legacy file untouched.
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: currentDir)) == currentBefore)
        #expect(try String(contentsOf: p3b2SnapshotURL(in: legacyDir), encoding: .utf8) == "not-json")
    }

    @Test
    func unsupportedLegacySchemaLeavesCurrentUntouched() async throws {
        let root = p3b2TmpRoot("schema-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        try p3b2WriteSnapshot(
            p3b2Snapshot([canvasID: [p3b2Asset(canvasID: canvasID, marker: "current")]]),
            to: currentDir
        )
        let currentBefore = try Data(contentsOf: p3b2SnapshotURL(in: currentDir))
        // Legacy JSON decodes structurally but declares an unsupported schema version.
        try p3b2WriteSnapshot(
            CanvasAssetStoreSnapshot(schemaVersion: 999, assetsByCanvas: [canvasID: [p3b2Asset(canvasID: canvasID, marker: "legacy")]]),
            to: legacyDir
        )

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )

        #expect(outcome == .legacyInvalid)
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: currentDir)) == currentBefore)
    }

    @Test
    func unreadableCurrentSnapshotLeftUntouched() async throws {
        let root = p3b2TmpRoot("unreadable-current")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        try p3b2WriteSnapshot(
            p3b2Snapshot([canvasID: [p3b2Asset(canvasID: canvasID, marker: "legacy")]]),
            to: legacyDir
        )
        try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
        try Data("corrupt-current".utf8).write(to: p3b2SnapshotURL(in: currentDir))

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )

        // Conservative: never overwrite a current snapshot we cannot decode.
        #expect(outcome == .currentUnreadableUntouched)
        #expect(try String(contentsOf: p3b2SnapshotURL(in: currentDir), encoding: .utf8) == "corrupt-current")
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: legacyDir)).isEmpty == false)
    }

    @Test
    func writeFailureLeavesCurrentUntouched() async throws {
        let root = p3b2TmpRoot("write-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let currentDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        let legacyAsset = p3b2Asset(canvasID: canvasID, marker: "legacy")
        try p3b2WriteSnapshot(p3b2Snapshot([canvasID: [legacyAsset]]), to: legacyDir)
        let legacyBefore = try Data(contentsOf: p3b2SnapshotURL(in: legacyDir))
        // currentDirectory is occupied by a regular file, so the atomic write cannot land.
        try Data("blocker".utf8).write(to: currentDir)

        let outcome = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: legacyDir,
            currentDirectory: currentDir
        )

        #expect(outcome == .writeFailed)
        // Legacy untouched; no current snapshot materialized.
        #expect(try Data(contentsOf: p3b2SnapshotURL(in: legacyDir)) == legacyBefore)
        #expect(try String(contentsOf: currentDir, encoding: .utf8) == "blocker")
        #expect(!FileManager.default.fileExists(atPath: p3b2SnapshotURL(in: currentDir).path))
    }

    @Test @MainActor
    func attachDraftStoreCallSiteMigratesLegacyBeforeCanonicalRestore() async throws {
        let root = p3b2TmpRoot("call-site")
        defer { try? FileManager.default.removeItem(at: root) }
        // The DraftStore root IS the legacy Session/DraftStore root.
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let taskDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        let legacyAsset = p3b2Asset(canvasID: canvasID, marker: "legacy")
        try p3b2WriteSnapshot(p3b2Snapshot([canvasID: [legacyAsset]]), to: legacyDir)

        let canvas = CanvasStore(
            videoTaskStore: VideoTaskStore(directory: taskDir),
            videoAssetDirectory: root.appendingPathComponent("videoAssets", isDirectory: true)
        )
        #expect(canvas.assetPersistenceDirectory == taskDir)
        canvas.attachDraftStore(DraftStore(directory: legacyDir))

        // The startup seam migrated the legacy snapshot into the canonical root
        // before the canonical load; the canonical file now contains the asset.
        let migrated = try #require(CanvasAssetStore.loadSnapshot(from: taskDir))
        #expect(migrated.assetsByCanvas[canvasID]?.first?.metadata["marker"] == "legacy")
        // Merged snapshot loads into the canonical store (deterministic seam, no
        // actor race): the restored store serves the migrated asset.
        let restored = CanvasAssetStore(snapshot: migrated)
        #expect(await restored.assets(canvasID: canvasID).map(\.id) == [legacyAsset.id])
        // Legacy snapshot retained.
        #expect(FileManager.default.fileExists(atPath: p3b2SnapshotURL(in: legacyDir).path))
    }

    @Test @MainActor
    func cleanExitAutoRestoreCallSiteMigratesLegacyBeforeCanonicalRead() async throws {
        let root = p3b2TmpRoot("clean-exit-call-site")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDir = root.appendingPathComponent("MinisCanvas", isDirectory: true)
        let taskDir = root.appendingPathComponent("MinisCore", isDirectory: true)
        let canvasID = UUID()
        let legacyAsset = p3b2Asset(canvasID: canvasID, marker: "legacy-clean-exit")
        try p3b2WriteSnapshot(p3b2Snapshot([canvasID: [legacyAsset]]), to: legacyDir)

        let canvas = CanvasStore(
            videoTaskStore: VideoTaskStore(directory: taskDir),
            videoAssetDirectory: root.appendingPathComponent("videoAssets", isDirectory: true)
        )
        // Invalid preloaded draft makes autoRestore return false, but migration must
        // still happen before the canonical snapshot read in this call-site.
        _ = AppLifecycleGuard.autoRestoreCanvasDraft(
            into: canvas,
            directory: legacyDir,
            preloadedData: Data("not-a-canvas-draft".utf8)
        )

        let migrated = try #require(CanvasAssetStore.loadSnapshot(from: taskDir))
        #expect(migrated.assetsByCanvas[canvasID]?.first?.metadata["marker"] == "legacy-clean-exit")
        #expect(FileManager.default.fileExists(atPath: p3b2SnapshotURL(in: legacyDir).path))
    }
}
