import Foundation

/// Privacy markings for environment variables: which names count as
/// secrets, and the default sensitive-name rules.
///
/// Ported from OpenMinis `Shared/EnvVarPrivacyStore.swift` (privacy-mode
/// toggle) — here it answers `isSecret(name:)` so `EnvVarStore` and
/// `EnvVarRedactor` can decide what to mask, and lets callers override the
/// defaults per name. Marks persist in `UserDefaults`.
public final class EnvVarPrivacyStore: @unchecked Sendable {
    public static let shared = EnvVarPrivacyStore()

    /// Default sensitive suffixes, matched against the uppercased name.
    /// Sensitive name components below also count unless explicitly unmarked.
    public static let defaultSensitiveSuffixes = ["API_KEY", "TOKEN", "SECRET", "PASSWORD", "KEY"]
    /// Sensitive words can also occur before a qualifier (for example,
    /// SECRET_TEST or SERVICE_CREDENTIAL_BLOB). Match whole name components so
    /// ordinary names such as SECRETARY remain non-sensitive.
    private static let defaultSensitiveComponents: Set<String> = [
        "SECRET", "TOKEN", "PASSWORD", "CREDENTIAL", "CREDENTIALS", "CRED", "AUTH"
    ]

    private static let markedKey = "envvar.secret_names"
    private static let unmarkedKey = "envvar.nonsecret_names"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Secret-free provenance for a variable-name privacy decision.
    ///
    /// This reports only the source of the classification; it never reads or
    /// returns the associated environment value.
    public enum PrivacyProvenance: String, Codable, Equatable, Sendable {
        case invalidName
        case explicitSecret
        case explicitNonSecret
        case defaultSensitive
        case unclassified

        public var isSecret: Bool {
            switch self {
            case .explicitSecret, .defaultSensitive:
                return true
            case .invalidName, .explicitNonSecret, .unclassified:
                return false
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True when `name` is explicitly marked secret, or matches the default
    /// sensitive suffix list and has not been explicitly unmarked.
    public func isSecret(name: String) -> Bool {
        provenance(name: name).isSecret
    }

    /// Return the non-sensitive source of the privacy decision for `name`.
    /// Invalid names never become durable marks or broad catch-all rules.
    public func provenance(name: String) -> PrivacyProvenance {
        let canonical = Self.canonicalName(name)
        guard Self.isUsableName(canonical) else { return .invalidName }
        lock.lock(); defer { lock.unlock() }
        if unmarkedLocked().contains(canonical) { return .explicitNonSecret }
        if markedLocked().contains(canonical) { return .explicitSecret }
        if Self.defaultSensitiveSuffixes.contains(where: { canonical.hasSuffix($0) })
            || canonical.split(separator: "_").contains(where: {
                Self.defaultSensitiveComponents.contains(String($0))
            }) {
            return .defaultSensitive
        }
        return .unclassified
    }

    /// Explicitly mark `name` as secret (persisted).
    public func markSecret(name: String) {
        let canonical = Self.canonicalName(name)
        guard Self.isUsableName(canonical) else { return }
        lock.lock(); defer { lock.unlock() }
        var marked = markedLocked()
        marked.insert(canonical)
        var unmarked = unmarkedLocked()
        unmarked.remove(canonical)
        persistLocked(marked: marked, unmarked: unmarked)
    }

    /// Explicitly unmark `name` (persisted). Overrides the default
    /// sensitive suffix list for this name.
    public func unmarkSecret(name: String) {
        let canonical = Self.canonicalName(name)
        guard Self.isUsableName(canonical) else { return }
        lock.lock(); defer { lock.unlock() }
        var marked = markedLocked()
        marked.remove(canonical)
        var unmarked = unmarkedLocked()
        unmarked.insert(canonical)
        persistLocked(marked: marked, unmarked: unmarked)
    }

    private func markedLocked() -> Set<String> {
        Set((defaults.stringArray(forKey: Self.markedKey) ?? []).map(Self.canonicalName).filter(Self.isUsableName))
    }

    private func unmarkedLocked() -> Set<String> {
        Set((defaults.stringArray(forKey: Self.unmarkedKey) ?? []).map(Self.canonicalName).filter(Self.isUsableName))
    }

    public static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private func persistLocked(marked: Set<String>, unmarked: Set<String>) {
        defaults.set(marked.sorted(), forKey: Self.markedKey)
        defaults.set(unmarked.sorted(), forKey: Self.unmarkedKey)
    }
}
