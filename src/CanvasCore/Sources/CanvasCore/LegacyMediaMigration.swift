import Foundation

public struct LegacyMediaMigrationResult: Equatable, Sendable {
    public let node: CanvasNode
    public let asset: MediaAsset

    public init(node: CanvasNode, asset: MediaAsset) {
        self.node = node
        self.asset = asset
    }
}

/// 旧节点结果字段到媒体资产的兼容迁移。纯函数、可重复执行，由上层负责持久化注册。
public enum LegacyMediaMigration {
    public static func asset(from node: CanvasNode, canvasID: UUID) -> MediaAsset? {
        guard let params = node.backendConfig?.params,
              let rawPath = params["result.path"] else {
            return nil
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let kind: MediaAssetKind
        switch params["result.kind"] {
        case "video": kind = .video
        case "image", nil: kind = .image
        default: return nil
        }
        let existingID = params["asset.id"].flatMap(UUID.init(uuidString:))
        let isRemote = path.hasPrefix("http://") || path.hasPrefix("https://")
        return MediaAsset(
            id: existingID ?? deterministicID(canvasID: canvasID, nodeID: node.id, path: path),
            kind: kind,
            source: .imported,
            status: .ready,
            localURL: isRemote ? nil : path,
            remoteURL: isRemote ? path : nil,
            sourceCanvasID: canvasID,
            sourceNodeID: node.id,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            metadata: ["legacy": "result-fields", "name": params["result.name"] ?? URL(fileURLWithPath: path).lastPathComponent]
        )
    }

    /// 将 legacy `result.*` 归一到稳定的 `asset.id`，保留旧字段供兼容读取。
    public static func canonicalize(node: CanvasNode, canvasID: UUID) -> LegacyMediaMigrationResult? {
        guard let asset = asset(from: node, canvasID: canvasID) else { return nil }
        var canonicalNode = node
        var config = canonicalNode.backendConfig ?? NodeBackendConfig()
        config.params["asset.id"] = asset.id.uuidString
        canonicalNode.backendConfig = config
        return LegacyMediaMigrationResult(node: canonicalNode, asset: asset)
    }

    /// 将一个图中所有旧节点转换为稳定、有序且无重复的资产列表。
    /// `existingAssets` 仅用于保留已经注册的实体，从而使重启/重复迁移幂等。
    public static func assets(
        from graph: NodeGraph,
        canvasID: UUID,
        existingAssets: [MediaAsset] = []
    ) -> [MediaAsset] {
        migrate(nodes: graph.nodes, canvasID: canvasID, existingAssets: existingAssets)
    }

    public static func migrate(
        nodes: [CanvasNode],
        canvasID: UUID,
        existingAssets: [MediaAsset] = []
    ) -> [MediaAsset] {
        var byID: [UUID: MediaAsset] = [:]
        for asset in existingAssets { byID[asset.id] = asset }
        var migrated: [MediaAsset] = []
        var seen: Set<UUID> = []

        for node in nodes {
            guard let candidate = asset(from: node, canvasID: canvasID), seen.insert(candidate.id).inserted else {
                continue
            }
            let asset = byID[candidate.id] ?? candidate
            byID[candidate.id] = asset
            migrated.append(asset)
        }
        return migrated
    }

    /// 迁移报告是纯 DTO，便于上层记录“哪些旧节点被处理”，不携带存储或 UI 状态。
    public struct Report: Codable, Equatable, Sendable {
        public static let currentSchemaVersion = CanvasSchema.currentVersion
        public let schemaVersion: Int
        public let assets: [MediaAsset]
        public let migratedNodeIDs: [UUID]

        public init(
            assets: [MediaAsset],
            migratedNodeIDs: [UUID],
            schemaVersion: Int = Report.currentSchemaVersion
        ) {
            self.schemaVersion = schemaVersion
            self.assets = assets
            self.migratedNodeIDs = migratedNodeIDs
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, assets, migratedNodeIDs }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
            self.assets = try c.decode([MediaAsset].self, forKey: .assets)
            self.migratedNodeIDs = try c.decode([UUID].self, forKey: .migratedNodeIDs)
        }
    }

    public static func report(
        nodes: [CanvasNode],
        canvasID: UUID,
        existingAssets: [MediaAsset] = []
    ) -> Report {
        let assets = migrate(nodes: nodes, canvasID: canvasID, existingAssets: existingAssets)
        let ids = nodes.compactMap { asset(from: $0, canvasID: canvasID)?.id }
        return Report(assets: assets, migratedNodeIDs: Array(Set(ids)).sorted { $0.uuidString < $1.uuidString })
    }

    private static func deterministicID(canvasID: UUID, nodeID: UUID, path: String) -> UUID {
        let bytes = Data("\(canvasID.uuidString)|\(nodeID.uuidString)|\(path)".utf8)
        var hash: UInt64 = 14695981039346656037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        var value = hash.bigEndian
        let raw = withUnsafeBytes(of: &value) { Data($0) }
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 { uuidBytes[index] = raw[index % 8] }
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        return UUID(uuid: (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3], uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7], uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11], uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
    }
}
