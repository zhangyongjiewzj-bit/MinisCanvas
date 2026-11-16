import CryptoKit
import Foundation

/// Errors raised when a capability manifest cannot be trusted by this build.
public enum CapabilityManifestError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(String)
    case unsupportedVersion(Int)
    case invalidProviderID
    case invalidOutputLimit(Int)
    case unknownCapability(String)
    case hashMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            return "Unsupported provider capability schema: \(schema)"
        case .unsupportedVersion(let version):
            return "Unsupported provider capability schema version: \(version)"
        case .invalidProviderID:
            return "Provider capability manifest has an empty provider id"
        case .invalidOutputLimit(let limit):
            return "Provider capability manifest has an invalid output limit: \(limit)"
        case .unknownCapability(let claim):
            return "Provider capability claim is unknown and was rejected: \(claim)"
        case .hashMismatch(let expected, let actual):
            return "Provider capability manifest hash mismatch (expected \(expected), got \(actual))"
        }
    }
}

/// The single authorization result consumed by routing and provider runtime
/// queries. Rejected claims remain observable but can never become grants.
public struct CapabilityManifestAuthorizationSnapshot: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    public let manifestHash: String
    public let requestedCapabilities: [ProviderCapability]
    public let grantedCapabilities: [ProviderCapability]
    public let deniedCapabilities: [ProviderCapability]
    public let rejectedClaims: [String]

    public var isAuthorized: Bool {
        deniedCapabilities.isEmpty && rejectedClaims.isEmpty
    }

    public func allows(_ capability: ProviderCapability) -> Bool {
        grantedCapabilities.contains(capability)
    }

    fileprivate init(
        providerID: String,
        manifestHash: String,
        requestedCapabilities: Set<ProviderCapability>,
        grantedCapabilities: Set<ProviderCapability>,
        rejectedClaims: [String] = []
    ) {
        self.providerID = providerID
        self.manifestHash = manifestHash
        self.requestedCapabilities = requestedCapabilities.sorted { $0.rawValue < $1.rawValue }
        self.grantedCapabilities = grantedCapabilities.sorted { $0.rawValue < $1.rawValue }
        self.deniedCapabilities = requestedCapabilities.subtracting(grantedCapabilities)
            .sorted { $0.rawValue < $1.rawValue }
        self.rejectedClaims = rejectedClaims
    }
}

/// Stable, credential-free description of the wire capabilities a provider
/// actually implements.
public struct CapabilityManifest: Codable, Equatable, Hashable, Sendable {
    public static let currentSchema = "miniscore.provider-capability-manifest"
    public static let currentVersion = 1
    public static let defaultMaximumOutputCharacters = 32_000

    public let schema: String
    public let version: Int
    public let providerID: String
    public let capabilities: [ProviderCapability]
    public let maxOutputCharacters: Int
    /// SHA-256 of the canonical, non-secret manifest fields.
    public let hash: String

    public init(
        providerID: String,
        capabilities: Set<ProviderCapability>,
        maxOutputCharacters: Int = CapabilityManifest.defaultMaximumOutputCharacters,
        schema: String = CapabilityManifest.currentSchema,
        version: Int = CapabilityManifest.currentVersion
    ) {
        self.schema = schema
        self.version = version
        self.providerID = providerID
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.maxOutputCharacters = max(1, maxOutputCharacters)
        self.hash = Self.makeHash(
            schema: schema,
            version: version,
            providerID: providerID,
            capabilities: self.capabilities,
            maxOutputCharacters: self.maxOutputCharacters
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(String.self, forKey: .schema)
        guard schema == Self.currentSchema else {
            throw CapabilityManifestError.unsupportedSchema(schema)
        }
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw CapabilityManifestError.unsupportedVersion(version)
        }
        let providerID = try container.decode(String.self, forKey: .providerID)
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapabilityManifestError.invalidProviderID
        }
        let capabilities = try container.decode([ProviderCapability].self, forKey: .capabilities)
        guard Set(capabilities).count == capabilities.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .capabilities,
                in: container,
                debugDescription: "Provider capability manifest contains duplicate capabilities"
            )
        }
        let maxOutputCharacters = try container.decode(Int.self, forKey: .maxOutputCharacters)
        guard maxOutputCharacters > 0 else {
            throw CapabilityManifestError.invalidOutputLimit(maxOutputCharacters)
        }
        let hash = try container.decode(String.self, forKey: .hash)
        let expected = Self.makeHash(
            schema: schema,
            version: version,
            providerID: providerID,
            capabilities: capabilities.sorted { $0.rawValue < $1.rawValue },
            maxOutputCharacters: maxOutputCharacters
        )
        guard hash == expected else {
            throw CapabilityManifestError.hashMismatch(expected: expected, actual: hash)
        }

        self.schema = schema
        self.version = version
        self.providerID = providerID
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.maxOutputCharacters = maxOutputCharacters
        self.hash = hash
    }

    public var capabilitySet: Set<ProviderCapability> { Set(capabilities) }
    public var schemaVersion: Int { version }
    public var manifestHash: String { hash }

    /// Resolve only typed capabilities against this manifest. This is the
    /// canonical authorization decision used by all production consumers.
    public func authorizationSnapshot(
        required: Set<ProviderCapability>
    ) -> CapabilityManifestAuthorizationSnapshot {
        CapabilityManifestAuthorizationSnapshot(
            providerID: providerID,
            manifestHash: hash,
            requestedCapabilities: required,
            grantedCapabilities: required.intersection(capabilitySet)
        )
    }

    /// Resolve mixed external claims without granting unknown strings or
    /// description-only claims. A rejected claim is retained for diagnostics.
    public func authorizationSnapshot(
        claims: [ProviderCapabilityClaim]
    ) -> CapabilityManifestAuthorizationSnapshot {
        var requested = Set<ProviderCapability>()
        var rejected: [String] = []
        for claim in claims {
            switch claim {
            case .typed(let capability): requested.insert(capability)
            case .description(let description): rejected.append(description)
            }
        }
        return CapabilityManifestAuthorizationSnapshot(
            providerID: providerID,
            manifestHash: hash,
            requestedCapabilities: requested,
            grantedCapabilities: requested.intersection(capabilitySet),
            rejectedClaims: rejected
        )
    }

    /// Raw strings are untrusted input. Unknown strings are rejected and
    /// returned as claims rather than being coerced into a capability.
    public func authorizationSnapshot(
        rawClaims: [String]
    ) -> CapabilityManifestAuthorizationSnapshot {
        authorizationSnapshot(claims: rawClaims.map { raw in
            ProviderCapability(rawValue: raw).map(ProviderCapabilityClaim.typed)
                ?? .description(raw)
        })
    }

    /// Strict variant for boundaries that must reject the whole request when
    /// an unknown string is present. No string is ever coerced into a grant.
    public func validatedAuthorizationSnapshot(
        rawClaims: [String]
    ) throws -> CapabilityManifestAuthorizationSnapshot {
        var typed = Set<ProviderCapability>()
        for raw in rawClaims {
            guard let capability = ProviderCapability(rawValue: raw) else {
                throw CapabilityManifestError.unknownCapability(raw)
            }
            typed.insert(capability)
        }
        return authorizationSnapshot(required: typed)
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, providerID, capabilities, maxOutputCharacters, hash
    }

    private static func makeHash(
        schema: String,
        version: Int,
        providerID: String,
        capabilities: [ProviderCapability],
        maxOutputCharacters: Int
    ) -> String {
        let canonical = [
            schema,
            String(version),
            providerID,
            capabilities.map(\.rawValue).joined(separator: ","),
            String(maxOutputCharacters),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// A point-in-time provider identity and capability view. It intentionally
/// contains no API key, endpoint credential, or environment value.
public struct CapabilityProviderSnapshot: Codable, Equatable, Hashable, Sendable {
    public static let currentSchema = "miniscore.provider-snapshot"
    public static let currentVersion = 1

    public let schema: String
    public let version: Int
    public let providerID: String
    public let name: String
    public let modelID: String
    public let capabilities: [ProviderCapability]
    public let capabilityManifestHash: String
    public let maxOutputCharacters: Int
    /// SHA-256 of this snapshot's public fields.
    public let hash: String

    public init(
        providerID: String,
        name: String,
        modelID: String,
        capabilities: Set<ProviderCapability>,
        maxOutputCharacters: Int = CapabilityManifest.defaultMaximumOutputCharacters,
        schema: String = CapabilityProviderSnapshot.currentSchema,
        version: Int = CapabilityProviderSnapshot.currentVersion
    ) {
        let manifest = CapabilityManifest(
            providerID: providerID,
            capabilities: capabilities,
            maxOutputCharacters: maxOutputCharacters
        )
        self.init(
            providerID: providerID,
            name: name,
            modelID: modelID,
            manifest: manifest,
            schema: schema,
            version: version
        )
    }

    public init(
        providerID: String,
        provider: any LLMProvider,
        maxOutputCharacters: Int = CapabilityManifest.defaultMaximumOutputCharacters
    ) {
        self.init(
            providerID: providerID,
            name: provider.name,
            modelID: provider.model.id,
            capabilities: provider.capabilities,
            maxOutputCharacters: maxOutputCharacters
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(String.self, forKey: .schema)
        guard schema == Self.currentSchema else {
            throw CapabilityManifestError.unsupportedSchema(schema)
        }
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw CapabilityManifestError.unsupportedVersion(version)
        }
        let providerID = try container.decode(String.self, forKey: .providerID)
        let name = try container.decode(String.self, forKey: .name)
        let modelID = try container.decode(String.self, forKey: .modelID)
        let capabilities = try container.decode([ProviderCapability].self, forKey: .capabilities)
        guard Set(capabilities).count == capabilities.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .capabilities,
                in: container,
                debugDescription: "Provider snapshot contains duplicate capabilities"
            )
        }
        let capabilityManifestHash = try container.decode(String.self, forKey: .capabilityManifestHash)
        let maxOutputCharacters = try container.decode(Int.self, forKey: .maxOutputCharacters)
        guard maxOutputCharacters > 0 else {
            throw CapabilityManifestError.invalidOutputLimit(maxOutputCharacters)
        }
        let hash = try container.decode(String.self, forKey: .hash)
        let expected = Self.makeHash(
            schema: schema,
            version: version,
            providerID: providerID,
            name: name,
            modelID: modelID,
            capabilities: capabilities.sorted { $0.rawValue < $1.rawValue },
            capabilityManifestHash: capabilityManifestHash,
            maxOutputCharacters: maxOutputCharacters
        )
        guard hash == expected else {
            throw CapabilityManifestError.hashMismatch(expected: expected, actual: hash)
        }
        let manifest = CapabilityManifest(
            providerID: providerID,
            capabilities: Set(capabilities),
            maxOutputCharacters: maxOutputCharacters
        )
        guard manifest.hash == capabilityManifestHash else {
            throw CapabilityManifestError.hashMismatch(expected: manifest.hash, actual: capabilityManifestHash)
        }

        self.schema = schema
        self.version = version
        self.providerID = providerID
        self.name = name
        self.modelID = modelID
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.capabilityManifestHash = capabilityManifestHash
        self.maxOutputCharacters = maxOutputCharacters
        self.hash = hash
    }

    public var capabilitySet: Set<ProviderCapability> { Set(capabilities) }
    public var schemaVersion: Int { version }
    public var manifestHash: String { capabilityManifestHash }

    public func authorizationSnapshot(
        required: Set<ProviderCapability>
    ) -> CapabilityManifestAuthorizationSnapshot {
        CapabilityManifestAuthorizationSnapshot(
            providerID: providerID,
            manifestHash: capabilityManifestHash,
            requestedCapabilities: required,
            grantedCapabilities: required.intersection(capabilitySet)
        )
    }

    private init(
        providerID: String,
        name: String,
        modelID: String,
        manifest: CapabilityManifest,
        schema: String,
        version: Int
    ) {
        self.schema = schema
        self.version = version
        self.providerID = providerID
        self.name = name
        self.modelID = modelID
        self.capabilities = manifest.capabilities
        self.capabilityManifestHash = manifest.hash
        self.maxOutputCharacters = manifest.maxOutputCharacters
        self.hash = Self.makeHash(
            schema: schema,
            version: version,
            providerID: providerID,
            name: name,
            modelID: modelID,
            capabilities: manifest.capabilities,
            capabilityManifestHash: manifest.hash,
            maxOutputCharacters: manifest.maxOutputCharacters
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, providerID, name, modelID, capabilities
        case capabilityManifestHash, maxOutputCharacters, hash
    }

    private static func makeHash(
        schema: String,
        version: Int,
        providerID: String,
        name: String,
        modelID: String,
        capabilities: [ProviderCapability],
        capabilityManifestHash: String,
        maxOutputCharacters: Int
    ) -> String {
        let canonical = [
            schema,
            String(version),
            providerID,
            name,
            modelID,
            capabilities.map(\.rawValue).joined(separator: ","),
            capabilityManifestHash,
            String(maxOutputCharacters),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public extension LLMProvider {
    /// Provider metadata for callers that need an auditable wire contract.
    var capabilityManifest: CapabilityManifest {
        CapabilityManifest(providerID: name, capabilities: capabilities)
    }

    var providerSnapshot: CapabilityProviderSnapshot {
        CapabilityProviderSnapshot(providerID: name, provider: self)
    }

    /// Production capability queries consume the same manifest authorization
    /// decision as routing instead of reading descriptive metadata directly.
    var capabilityAuthorizationSnapshot: CapabilityManifestAuthorizationSnapshot {
        capabilityManifest.authorizationSnapshot(required: capabilities)
    }

    func supportsDeclaredCapability(_ capability: ProviderCapability) -> Bool {
        capabilityManifest.authorizationSnapshot(required: [capability]).isAuthorized
    }
}
