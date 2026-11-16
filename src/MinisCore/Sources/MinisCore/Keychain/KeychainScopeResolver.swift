import Foundation

/// The provider aliases that are allowed to participate in credential scope
/// resolution.  A scope is an identity only; it never contains a credential
/// value.
public enum KeychainCredentialAlias: String, CaseIterable, Codable, Hashable, Sendable {
    case deepSeek = "DEEPSEEK_API_KEY"
    case hermesCustomDeepSeek = "HERMES_CUSTOM_DEEPSEEK_API_KEY"
    case openAI = "OPENAI_API_KEY"
    case anthropic = "ANTHROPIC_API_KEY"
    case gemini = "GEMINI_API_KEY"
    case openRouter = "OPENROUTER_API_KEY"
    case dashScope = "DASHSCOPE_API_KEY"

    public var providerID: String {
        switch self {
        case .deepSeek, .hermesCustomDeepSeek:
            return "deepseek"
        case .openAI:
            return "openai"
        case .anthropic:
            return "anthropic"
        case .gemini:
            return "gemini"
        case .openRouter:
            return "openrouter"
        case .dashScope:
            return "dashscope"
        }
    }
}

/// Stable Keychain namespace identity.  `account` is a canonical alias, not
/// the secret stored under that account.
public struct KeychainScopeIdentity: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    /// Bundle identity is metadata only and never contains a credential.
    public let bundleIdentifier: String?
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        providerID: String,
        service: String,
        account: String,
        accessGroup: String? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.providerID = providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.service = service.trimmingCharacters(in: .whitespacesAndNewlines)
        self.account = account
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let trimmedAccessGroup = accessGroup?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessGroup = trimmedAccessGroup?.isEmpty == true
            ? nil
            : trimmedAccessGroup
        let trimmedBundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleIdentifier = trimmedBundle?.isEmpty == true ? nil : trimmedBundle
    }
}

/// A typed result for a current namespace lookup.  The `rebind` case tells a
/// caller which old identity may be read before copying into `canonical`.
/// Deletion and plaintext transport are intentionally outside this contract.
public enum KeychainScopeResolution: Equatable, Sendable {
    case canonical(KeychainScopeIdentity)
    case rebind(canonical: KeychainScopeIdentity, legacy: [KeychainScopeIdentity])
}

/// Resolves the small, explicit Keychain namespace surface used by provider
/// credentials.  Unknown provider/alias combinations and arbitrary legacy
/// services fail closed instead of becoming a Keychain scanner.
public enum KeychainScopeResolver {
    /// The service used by the pre-successor app and the normal production
    /// store.  Packaged-field callers may provide a different canonical
    /// service and receive this service as the only eligible legacy alias.
    public static let legacyService = KeychainStore.defaultService

    /// Build a canonical scope, optionally with the one fixed legacy service.
    /// No Keychain operation occurs here; this is a pure typed plan.
    public static func resolve(
        providerID: String,
        account: String,
        canonicalService: String = legacyService,
        canonicalAccessGroup: String? = nil,
        legacyServices: [String] = [],
        legacyAccessGroup: String? = nil,
        canonicalBundleIdentifier: String? = nil,
        legacyBundleIdentifiers: [String] = []
    ) -> KeychainScopeResolution? {
        guard let alias = KeychainCredentialAlias(rawValue: canonicalAccount(account)),
              providerMatches(providerID, alias: alias) else {
            return nil
        }

        let service = canonicalService.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeNamespaceComponent(service),
              isSafeOptionalNamespaceComponent(canonicalAccessGroup),
              isSafeOptionalNamespaceComponent(canonicalBundleIdentifier) else { return nil }
        let canonical = KeychainScopeIdentity(
            providerID: alias.providerID,
            service: service,
            account: alias.rawValue,
            accessGroup: canonicalAccessGroup,
            bundleIdentifier: canonicalBundleIdentifier
        )

        var seen = Set<KeychainScopeIdentity>()
        var legacy: [KeychainScopeIdentity] = []
        for candidate in legacyServices {
            let legacyService = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard legacyService == legacyServiceName,
                  isSafeNamespaceComponent(legacyService),
                  isSafeOptionalNamespaceComponent(legacyAccessGroup),
                  legacyService != canonical.service else { continue }
            let bundles: [String?] = legacyBundleIdentifiers.isEmpty
                ? [nil]
                : legacyBundleIdentifiers.compactMap { bundle in
                    let trimmed = bundle.trimmingCharacters(in: .whitespacesAndNewlines)
                    return isSafeNamespaceComponent(trimmed) ? trimmed : nil
                }.map { Optional($0) }
            for bundle in bundles {
                let identity = KeychainScopeIdentity(
                    providerID: alias.providerID,
                    service: legacyService,
                    account: alias.rawValue,
                    accessGroup: legacyAccessGroup,
                    bundleIdentifier: bundle
                )
                guard identity != canonical, seen.insert(identity).inserted else { continue }
                legacy.append(identity)
            }
        }
        if legacy.isEmpty {
            return .canonical(canonical)
        }
        return .rebind(canonical: canonical, legacy: legacy)
    }

    /// Account aliases are exact and finite.  Trimming/casing is the only
    /// normalization; no free-form key name can enter the resolver.
    private static func canonicalAccount(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func providerMatches(
        _ providerID: String,
        alias: KeychainCredentialAlias
    ) -> Bool {
        let normalized = providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == alias.providerID
            || normalized == "builtin.\(alias.providerID)"
            || (alias.providerID == "deepseek" && normalized == "deepseekprovider")
    }

    private static func isSafeNamespaceComponent(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace
                && !CharacterSet.controlCharacters.contains($0)
                && $0 != "/"
        }
    }

    private static func isSafeOptionalNamespaceComponent(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || isSafeNamespaceComponent(trimmed)
    }

    private static var legacyServiceName: String { legacyService }
}
