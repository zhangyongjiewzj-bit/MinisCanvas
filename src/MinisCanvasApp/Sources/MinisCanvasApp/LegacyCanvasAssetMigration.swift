import Foundation
import CanvasCore

/// B2: conservative legacy -> current canvas asset snapshot migration.
///
/// Paths (see SessionStore.defaultDirectory / VideoTaskStore.defaultDirectory):
///   legacy  = Session/DraftStore root -> <AppSupport>/MinisCanvas/canvas_assets.json
///   current = VideoTaskStore root     -> <AppSupport>/MinisCore/canvas_assets.json
///
/// Policy:
///   - current missing + legacy decodes -> atomically copy legacy to current; legacy retained.
///   - both exist + both decode         -> merge by (canvasID, assetID): preserve the union of
///     all asset records and canvas mappings; for a duplicate asset ID the current snapshot
///     wins deterministically; legacy is never deleted; the only current write is the merged
///     union (skipped when the union is already equivalent -> idempotent).
///   - legacy missing / invalid (decode failure or unsupported schema version) -> leave current
///     untouched, emit no destructive action.
///   - current exists but cannot be decoded -> leave current untouched (never overwrite a
///     current snapshot we cannot read with a merge that could drop data).
///
/// Invoked at the startup call-site seam (CanvasStore.attachDraftStore) - deliberately NOT
/// inside CanvasAssetStore.loadSnapshot, so the existing root assertion tests keep their
/// exact behavior. No GUI, no network, no App launch.
///
/// OPEN (documented, not migrated): canvas_assets.previous.json - no producer or consumer of
/// that file exists anywhere in the current codebase (grep canvas_assets.previous returns
/// nothing), so there is no test/design justification for migrating it. Left as an open item
/// for owner decision; this migration only ever reads/writes the two canvas_assets.json paths
/// above and never touches a .previous file.
enum LegacyCanvasAssetMigration {
    enum Outcome: Equatable, Sendable {
        /// No legacy snapshot exists at the legacy root; nothing to do.
        case noLegacySnapshot
        /// Legacy exists but cannot be decoded (or declares an unsupported schema
        /// version); current left untouched.
        case legacyInvalid
        /// Current snapshot exists but cannot be decoded; left untouched.
        case currentUnreadableUntouched
        /// Current snapshot was missing; legacy was atomically copied to current.
        case copiedLegacyToCurrent
        /// Both decoded; the merged union was written to current.
        case merged
        /// Both decoded and already equivalent; no write performed.
        case alreadySynchronized
        /// The atomic copy/merge write failed; current left untouched.
        case writeFailed
    }

    /// Runs the conservative migration once. Idempotent: repeated runs converge to
    /// .alreadySynchronized / .noLegacySnapshot and never rewrite equivalent state.
    @discardableResult
    static func migrateIfNeeded(
        legacyDirectory: URL,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) -> Outcome {
        let legacyURL = legacyDirectory.appendingPathComponent(CanvasAssetStore.snapshotFileName)
        guard let legacyData = try? Data(contentsOf: legacyURL) else {
            return .noLegacySnapshot
        }
        guard let legacy = try? JSONDecoder().decode(CanvasAssetStoreSnapshot.self, from: legacyData),
              legacy.schemaVersion == CanvasAssetStore.currentSchemaVersion else {
            // Unreadable or unsupported legacy snapshot: leave current untouched.
            return .legacyInvalid
        }

        let currentURL = currentDirectory.appendingPathComponent(CanvasAssetStore.snapshotFileName)
        let currentExists = fileManager.fileExists(atPath: currentURL.path)
        if currentExists,
           let currentData = try? Data(contentsOf: currentURL),
           let current = try? JSONDecoder().decode(CanvasAssetStoreSnapshot.self, from: currentData) {
            // Both snapshots exist and decode -> merge; current wins per asset ID.
            let merged = merge(current: current, legacy: legacy)
            guard !isEquivalent(merged, current) else { return .alreadySynchronized }
            return write(merged, to: currentURL, fileManager: fileManager) ? .merged : .writeFailed
        }
        // Current missing -> atomic copy of the legacy bytes; current exists but unreadable
        // -> untouched (conservative, no destructive action).
        guard !currentExists else { return .currentUnreadableUntouched }
        return writeRaw(legacyData, to: currentURL, fileManager: fileManager)
            ? .copiedLegacyToCurrent
            : .writeFailed
    }

    /// Union merge by (canvasID, assetID). Duplicate asset IDs within a canvas resolve to the
    /// current snapshot's record deterministically - the policy is "current wins", not version
    /// arbitration. Output arrays are sorted by asset ID so the merged file is deterministic.
    static func merge(
        current: CanvasAssetStoreSnapshot,
        legacy: CanvasAssetStoreSnapshot
    ) -> CanvasAssetStoreSnapshot {
        var byCanvas: [UUID: [UUID: MediaAsset]] = [:]
        for (canvasID, assets) in legacy.assetsByCanvas {
            byCanvas[canvasID] = assets.reduce(into: [:]) { $0[$1.id] = $1 }
        }
        for (canvasID, assets) in current.assetsByCanvas {
            var byID = byCanvas[canvasID] ?? [:]
            for asset in assets {
                byID[asset.id] = asset // current wins deterministically
            }
            byCanvas[canvasID] = byID
        }
        let merged = byCanvas.mapValues { byID in
            byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        return CanvasAssetStoreSnapshot(
            schemaVersion: current.schemaVersion,
            assetsByCanvas: merged
        )
    }

    private static func write(
        _ snapshot: CanvasAssetStoreSnapshot,
        to url: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func writeRaw(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Order-insensitive equivalence: same schema version and same set of asset IDs per canvas.
    private static func isEquivalent(
        _ a: CanvasAssetStoreSnapshot,
        _ b: CanvasAssetStoreSnapshot
    ) -> Bool {
        guard a.schemaVersion == b.schemaVersion else { return false }
        let keys = Set(a.assetsByCanvas.keys).union(b.assetsByCanvas.keys)
        for key in keys {
            if sortedAssets(a.assetsByCanvas[key] ?? []) != sortedAssets(b.assetsByCanvas[key] ?? []) {
                return false
            }
        }
        return true
    }

    private static func sortedAssets(_ assets: [MediaAsset]) -> [MediaAsset] {
        assets.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
