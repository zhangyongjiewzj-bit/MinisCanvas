import Foundation

public enum EnvCredentialScope: String, Codable, Equatable, Hashable, Sendable {
    case apiKey, accessKey, secretKey, token, password, genericKey
    case endpointURL, modelConfiguration, testFixture

    public var isCredential: Bool {
        switch self {
        case .apiKey, .accessKey, .secretKey, .token, .password, .genericKey: return true
        case .endpointURL, .modelConfiguration, .testFixture: return false
        }
    }
}

public struct EnvCredentialIdentity: Codable, Equatable, Hashable, Sendable {
    public let canonicalName: String
    public let scope: EnvCredentialScope
    public init(canonicalName: String, scope: EnvCredentialScope) {
        self.canonicalName = canonicalName
        self.scope = scope
    }
}

public enum EnvCredentialSource: String, Codable, Equatable, Sendable {
    case process, supplementary
}

public struct EnvCredentialResolution: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case configured, unset, invalidName, disallowedName
    }
    public let identity: EnvCredentialIdentity?
    public let source: EnvCredentialSource?
    public let status: Status
    public init(identity: EnvCredentialIdentity?, source: EnvCredentialSource?, status: Status) {
        self.identity = identity
        self.source = source
        self.status = status
    }
}

public enum EnvCredentialsError: Error, Equatable, Sendable {
    case invalidName, disallowedName
}

public enum EnvCredentials {
    private final class SupplementaryStorage: @unchecked Sendable {
        let lock = NSLock()
        var source: (@Sendable (String) -> String?)?

        func read() -> (@Sendable (String) -> String?)? {
            lock.lock()
            defer { lock.unlock() }
            return source
        }

        func write(_ source: (@Sendable (String) -> String?)?) {
            lock.lock()
            defer { lock.unlock() }
            self.source = source
        }
    }

    private static let storage = SupplementaryStorage()

    public static var supplementarySource: (@Sendable (String) -> String?)? {
        get { storage.read() }
        set { storage.write(newValue) }
    }

    public static func canonicalName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let bytes = Array(name.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first,
              isLetter(first), bytes.allSatisfy({ isLetter($0) || (48...57).contains($0) || $0 == 95 }) else {
            return nil
        }
        return name.uppercased()
    }

    public static func identity(for name: String) throws -> EnvCredentialIdentity {
        guard let name = canonicalName(name) else { throw EnvCredentialsError.invalidName }
        guard let scope = scope(for: name) else { throw EnvCredentialsError.disallowedName }
        return EnvCredentialIdentity(canonicalName: name, scope: scope)
    }

    public static func resolution(for name: String?) -> EnvCredentialResolution {
        guard let name = canonicalName(name) else {
            return EnvCredentialResolution(identity: nil, source: nil, status: .invalidName)
        }
        guard let scope = scope(for: name) else {
            return EnvCredentialResolution(identity: nil, source: nil, status: .disallowedName)
        }
        let identity = EnvCredentialIdentity(canonicalName: name, scope: scope)
        if let found = lookup(name) {
            return EnvCredentialResolution(identity: identity, source: found.source, status: .configured)
        }
        return EnvCredentialResolution(identity: identity, source: nil, status: .unset)
    }

    public static func value(for name: String) -> String? {
        guard let identity = try? identity(for: name) else { return nil }
        return lookup(identity.canonicalName)?.value
    }

    public static func apiKey(envVar: String?) -> String? {
        guard let envVar, let identity = try? identity(for: envVar), identity.scope.isCredential else {
            return nil
        }
        return lookup(identity.canonicalName)?.value
    }

    public static func configuredProviderCredential(for record: EnvVarEntry, current: EnvVarEntry?) -> String? {
        guard let current, current == record, record.isProviderRecord, record.isSecret,
              let canonical = canonicalName(record.name), canonical == record.name else { return nil }
        if let knownScope = scope(for: canonical), !knownScope.isCredential { return nil }
        if !record.value.isEmpty { return record.value }
        guard record.valueInKeychain else { return nil }
        return nonempty(storage.read()?(canonical))
    }

    private static func lookup(_ canonical: String) -> (value: String, source: EnvCredentialSource)? {
        if let value = nonempty(ProcessInfo.processInfo.environment[canonical]) {
            return (value, .process)
        }
        if let value = nonempty(storage.read()?(canonical)) {
            return (value, .supplementary)
        }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func scope(for name: String) -> EnvCredentialScope? {
        if name == "GIMAGE2_MODEL_G2" { return .modelConfiguration }
        if name.hasPrefix("F6_TEST_") { return .testFixture }
        if name.hasSuffix("_BASE_URL") { return .endpointURL }
        if name.hasSuffix("_API_KEY") { return .apiKey }
        if name.hasSuffix("_ACCESS_KEY") || name.hasSuffix("_ACCESSKEY") { return .accessKey }
        if name.hasSuffix("_SECRET_KEY") || name.hasSuffix("_SECRETKEY") { return .secretKey }
        if name.hasSuffix("_TOKEN") { return .token }
        if name.hasSuffix("_PASSWORD") { return .password }
        if name.hasSuffix("_KEY") { return .genericKey }
        return nil
    }
}
