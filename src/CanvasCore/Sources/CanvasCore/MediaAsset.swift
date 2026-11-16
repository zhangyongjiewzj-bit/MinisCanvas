import Foundation

/// 媒体资产的内容类型。二期先覆盖图片和视频，其他类型以后通过新 case 扩展。
public enum MediaAssetKind: String, Codable, Sendable, Equatable {
    case image
    case video
    case frameSet
}

/// 资产来源，用于展示来源和迁移诊断，不授予任何执行权限。
public enum MediaAssetSource: Codable, Sendable, Equatable {
    case imported
    case generated
    case remote
    case extracted
    case saved
    case derived(parentID: UUID)

    private enum CodingKeys: String, CodingKey { case kind, parentID }
    private enum Kind: String, Codable { case imported, generated, remote, extracted, saved, derived }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .imported:
            try container.encode(Kind.imported, forKey: .kind)
        case .generated:
            try container.encode(Kind.generated, forKey: .kind)
        case .remote:
            try container.encode(Kind.remote, forKey: .kind)
        case .extracted:
            try container.encode(Kind.extracted, forKey: .kind)
        case .saved:
            try container.encode(Kind.saved, forKey: .kind)
        case .derived(let parentID):
            try container.encode(Kind.derived, forKey: .kind)
            try container.encode(parentID, forKey: .parentID)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .imported: self = .imported
        case .generated: self = .generated
        case .remote: self = .remote
        case .extracted: self = .extracted
        case .saved: self = .saved
        case .derived: self = .derived(parentID: try container.decode(UUID.self, forKey: .parentID))
        }
    }
}

public enum MediaAssetStatus: String, Codable, Sendable, Equatable {
    case importing
    case queued
    case generating
    case downloading
    case ready
    case failed
    case cancelled
    case deleted
}

/// 资产事实源。节点只应保存 assetID，临时 result.* 仅用于兼容迁移。
public struct MediaAsset: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public var kind: MediaAssetKind
    public var source: MediaAssetSource
    public var status: MediaAssetStatus
    public var localURL: String?
    public var remoteURL: String?
    public var thumbnailURL: String?
    public var sourceCanvasID: UUID?
    public var sourceNodeID: UUID?
    public var runID: UUID?
    public var jobID: String?
    public var providerID: String?
    public var version: Int
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var frameRate: Double?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]
    public var failureCode: String?

    public init(
        id: UUID = UUID(),
        kind: MediaAssetKind,
        source: MediaAssetSource,
        status: MediaAssetStatus = .ready,
        localURL: String? = nil,
        remoteURL: String? = nil,
        thumbnailURL: String? = nil,
        sourceCanvasID: UUID? = nil,
        sourceNodeID: UUID? = nil,
        runID: UUID? = nil,
        jobID: String? = nil,
        providerID: String? = nil,
        version: Int = 1,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        frameRate: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:],
        failureCode: String? = nil,
        schemaVersion: Int = MediaAsset.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.source = source
        self.status = status
        self.localURL = localURL
        self.remoteURL = remoteURL
        self.thumbnailURL = thumbnailURL
        self.sourceCanvasID = sourceCanvasID
        self.sourceNodeID = sourceNodeID
        self.runID = runID
        self.jobID = jobID
        self.providerID = providerID
        self.version = max(1, version)
        self.width = width
        self.height = height
        self.duration = duration
        self.frameRate = frameRate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
        self.failureCode = failureCode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, source, status, localURL, remoteURL, thumbnailURL
        case sourceCanvasID, sourceNodeID, runID, jobID, providerID, version
        case width, height, duration, frameRate, createdAt, updatedAt, metadata, failureCode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(MediaAssetKind.self, forKey: .kind)
        self.source = try c.decode(MediaAssetSource.self, forKey: .source)
        self.status = try c.decode(MediaAssetStatus.self, forKey: .status)
        self.localURL = try c.decodeIfPresent(String.self, forKey: .localURL)
        self.remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
        self.thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        self.sourceCanvasID = try c.decodeIfPresent(UUID.self, forKey: .sourceCanvasID)
        self.sourceNodeID = try c.decodeIfPresent(UUID.self, forKey: .sourceNodeID)
        self.runID = try c.decodeIfPresent(UUID.self, forKey: .runID)
        self.jobID = try c.decodeIfPresent(String.self, forKey: .jobID)
        self.providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        self.version = try c.decode(Int.self, forKey: .version)
        self.width = try c.decodeIfPresent(Int.self, forKey: .width)
        self.height = try c.decodeIfPresent(Int.self, forKey: .height)
        self.duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        self.frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.metadata = try c.decode([String: String].self, forKey: .metadata)
        self.failureCode = try c.decodeIfPresent(String.self, forKey: .failureCode)
        try validate()
    }

    public func validate() throws {
        guard version > 0 else { throw CanvasSchemaError.invalidField("asset.version") }
        if let width { guard width > 0 else { throw CanvasSchemaError.invalidField("asset.width") } }
        if let height { guard height > 0 else { throw CanvasSchemaError.invalidField("asset.height") } }
        if let duration { guard duration.isFinite, duration >= 0 else { throw CanvasSchemaError.invalidField("asset.duration") } }
        if let frameRate { guard frameRate.isFinite, frameRate > 0 else { throw CanvasSchemaError.invalidField("asset.frameRate") } }
        if status == .ready && normalizedPath(localURL) == nil && normalizedPath(remoteURL) == nil {
            throw CanvasSchemaError.invalidField("asset.path")
        }
        if let remoteURL, !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !(remoteURL.hasPrefix("http://") || remoteURL.hasPrefix("https://")) {
            throw CanvasSchemaError.invalidField("asset.remoteURL")
        }
    }

    public var isValid: Bool { (try? validate()) != nil }

    private func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Canonical media lookup used by execution and presentation projections.
/// Implementations own canvas scoping and persistence; CanvasCore only needs
/// the stable asset identity, never a legacy `result.*` path.
public protocol MediaAssetResolving: Sendable {
    func asset(id: UUID) async -> MediaAsset?
}

/// 节点/执行层传递的媒体值，不携带可变 UI 或 Provider 对象。
/// `assetReference` 是旧节点的轻量引用兼容形式；新业务优先传递资产实体或有序资产集合。
public enum MediaValue: Codable, Sendable, Equatable {
    case asset(MediaAsset)
    case assets([MediaAsset])
    case frameSet([MediaAsset])
    case assetReference(assetID: UUID, kind: MediaAssetKind)

    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public var schemaVersion: Int { Self.currentSchemaVersion }

    /// 兼容二期早期的轻量引用构造器。
    public init(assetID: UUID, kind: MediaAssetKind) {
        self = .assetReference(assetID: assetID, kind: kind)
    }

    public var assetID: UUID? {
        switch self {
        case let .asset(asset): return asset.id
        case let .assetReference(assetID, _): return assetID
        case .assets, .frameSet: return nil
        }
    }

    public var kind: MediaAssetKind {
        switch self {
        case let .asset(asset): return asset.kind
        case let .assetReference(_, kind): return kind
        case let .assets(assets): return commonKind(of: assets) ?? .frameSet
        case .frameSet: return .frameSet
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, valueKind, asset, assets, assetID, kind
    }

    private enum ValueKind: String, Codable { case asset, assets, frameSet, assetReference }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CanvasSchema.currentVersion, forKey: .schemaVersion)
        switch self {
        case let .asset(asset):
            try c.encode(ValueKind.asset, forKey: .valueKind)
            try c.encode(asset, forKey: .asset)
        case let .assets(assets):
            try c.encode(ValueKind.assets, forKey: .valueKind)
            try c.encode(assets, forKey: .assets)
        case let .frameSet(assets):
            try c.encode(ValueKind.frameSet, forKey: .valueKind)
            try c.encode(assets, forKey: .assets)
        case let .assetReference(assetID, kind):
            try c.encode(ValueKind.assetReference, forKey: .valueKind)
            try c.encode(assetID, forKey: .assetID)
            try c.encode(kind, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        if let valueKind = try c.decodeIfPresent(ValueKind.self, forKey: .valueKind) {
            switch valueKind {
            case .asset: self = .asset(try c.decode(MediaAsset.self, forKey: .asset))
            case .assets:
                let values = try c.decode([MediaAsset].self, forKey: .assets)
                self = .assets(values)
            case .frameSet:
                let values = try c.decode([MediaAsset].self, forKey: .assets)
                self = .frameSet(values)
            case .assetReference:
                self = .assetReference(
                    assetID: try c.decode(UUID.self, forKey: .assetID),
                    kind: try c.decode(MediaAssetKind.self, forKey: .kind)
                )
            }
        } else {
            // Decode the pre-schema lightweight reference without accepting partial values.
            self = .assetReference(
                assetID: try c.decode(UUID.self, forKey: .assetID),
                kind: try c.decode(MediaAssetKind.self, forKey: .kind)
            )
        }
        try validate()
    }

    public func validate() throws {
        switch self {
        case let .asset(asset): try asset.validate()
        case .assetReference: break
        case let .assets(assets):
            guard !assets.isEmpty, assets.count <= 10 else { throw CanvasSchemaError.invalidField("media.assets.count") }
            try assets.forEach { try $0.validate() }
            guard Set(assets.map(\.id)).count == assets.count else {
                throw CanvasSchemaError.invalidField("media.assets.ids")
            }
        case let .frameSet(assets):
            guard !assets.isEmpty else { throw CanvasSchemaError.invalidField("media.frameSet.count") }
            try assets.forEach { try $0.validate() }
            guard Set(assets.map(\.id)).count == assets.count else {
                throw CanvasSchemaError.invalidField("media.frameSet.ids")
            }
        }
    }

    private func commonKind(of assets: [MediaAsset]) -> MediaAssetKind? {
        guard let first = assets.first?.kind, assets.allSatisfy({ $0.kind == first }) else { return nil }
        return first
    }
}
