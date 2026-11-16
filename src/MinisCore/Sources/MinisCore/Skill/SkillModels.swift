import Foundation
import CryptoKit

/// Provenance is independent of the display name and the installation location.
public enum SkillImportSource: Codable, Equatable, Hashable, Sendable {
    case url(String)
    case file
    case bundled
    case session

    public var sourceURL: String? {
        guard case let .url(value) = self else { return nil }
        return value
    }

    public var dbValue: String {
        switch self {
        case let .url(value): return "url:" + value
        case .file: return "file"
        case .bundled: return "bundled"
        case .session: return "session"
        }
    }

    public static func fromDB(_ value: String) -> Self {
        if value.hasPrefix("url:") { return .url(String(value.dropFirst(4))) }
        switch value {
        case "bundled": return .bundled
        case "session": return .session
        default: return .file
        }
    }
}

public struct SkillSourceManifest: Codable, Equatable, Hashable, Sendable {
    public static let currentSchema = "miniscore.skill-source-manifest"
    public static let currentVersion = 1
    public let schema: String
    public let version: Int
    public let skillID: String
    public let source: SkillImportSource
    public let skillVersion: String
    public let contentHash: String

    public init(schema: String = "miniscore.skill-source-manifest", version: Int = 1,
                skillID: String, source: SkillImportSource, skillVersion: String,
                contentHash: String) {
        self.schema = schema
        self.version = version
        self.skillID = skillID
        self.source = source
        self.skillVersion = skillVersion
        self.contentHash = contentHash
    }

    public init(skillID: String, source: SkillImportSource, skillVersion: String, content: String,
                schema: String = Self.currentSchema, version: Int = Self.currentVersion) {
        self.init(schema: schema, version: version, skillID: skillID, source: source, skillVersion: skillVersion,
                  contentHash: Self.hash(content))
    }

    public static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SkillIntegrityState: String, Codable, Hashable, Sendable {
    case verified, missingManifest, malformedManifest, manifestMismatch, hashMismatch, quarantined
}

public struct SkillIntegrity: Codable, Equatable, Hashable, Sendable {
    public typealias State = SkillIntegrityState

    public let state: State
    public let manifest: SkillSourceManifest?
    public let observedContentHash: String?

    public init(state: State, manifest: SkillSourceManifest? = nil, observedContentHash: String? = nil) {
        self.state = state
        self.manifest = manifest
        self.observedContentHash = observedContentHash
    }

    public static let missing = Self(state: .missingManifest)
    public static let missingManifest = missing
}

public struct Skill: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    public var version: String
    public var importSource: SkillImportSource
    public var isEnabled: Bool
    public var installedAt: Date
    public var updatedAt: Date
    public var body: String
    public var integrity: SkillIntegrity
    public var useCount: Double

    public var sourceURL: String? { importSource.sourceURL }

    public init(id: String, name: String, description: String, version: String,
                importSource: SkillImportSource, isEnabled: Bool = true,
                installedAt: Date = Date(), updatedAt: Date = Date(), body: String = "",
                useCount: Double = 0, integrity: SkillIntegrity = .missing) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.importSource = importSource
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.body = body
        self.integrity = integrity
        self.useCount = useCount
    }
}

public enum SkillError: Error, Equatable, Sendable {
    case invalidContent
    case contentTooLarge
    case skillNotFound(String)
    case noSkillMD(at: String)
    case importFailed(reason: String)
}
