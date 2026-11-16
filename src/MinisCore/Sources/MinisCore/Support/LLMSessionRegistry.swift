import CryptoKit
import Foundation

/// A registered LLM provider session that can be reused across requests
/// (OpenAI-compatible session reuse). Keyed by provider plus optional session
/// identity; re-registering the same key replaces its token (session hand-off).
public struct LLMSessionEntry: Sendable, Equatable {
    public let providerID: String
    /// Optional session identity for consumers that bind a provider session to
    /// a persisted chat session. A nil value preserves provider-only callers.
    public let sessionID: String?
    public let sessionToken: String
    public let registeredAt: Date
    /// Monotonic generation for this provider/session key. Rebinds fence the
    /// previous entry even when the provider and token remain otherwise valid.
    public let generation: UInt64

    public init(
        providerID: String,
        sessionToken: String,
        registeredAt: Date = Date(),
        sessionID: String? = nil,
        generation: UInt64 = 0
    ) {
        self.providerID = providerID
        self.sessionID = sessionID
        self.sessionToken = sessionToken
        self.registeredAt = registeredAt
        self.generation = generation
    }

    /// Opaque stable identity that excludes both wall-clock time and raw
    /// provider/session content from logs or downstream receipts.
    public var stableID: String {
        let session = sessionID.map { "\($0.utf8.count):\($0)" } ?? "-"
        let canonical = "\(providerID.utf8.count):\(providerID)#\(session)#\(generation)"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Central registry of reusable LLM sessions (adapted from OpenMinis
/// `LLMSessionRegistry.swift`). The OpenMinis original tracks `URLSession`
/// connection pools to evict on network transitions; this variant tracks
/// provider-level session tokens so OpenAI-compatible providers can reuse a
/// live session instead of re-handshaking, and can be invalidated when a
/// network/interface change makes pooled connections suspect.
public final class LLMSessionRegistry: @unchecked Sendable {
    public static let shared = LLMSessionRegistry()

    private struct RegistryKey: Hashable {
        let providerID: String
        let sessionID: String?
    }

    private let lock = NSLock()
    private var entries: [RegistryKey: LLMSessionEntry] = [:]
    /// Generation counters survive invalidation so an old entry can never
    /// become current after a rebind on the same registry instance.
    private var generations: [RegistryKey: UInt64] = [:]
    /// A key that reaches the generation ceiling is retired rather than
    /// wrapping and accidentally reviving an old entry.
    private var exhaustedKeys: Set<RegistryKey> = []

    public init() {}

    /// Register (or replace) a session token for a provider. Returns the entry.
    @discardableResult
    public func register(providerID: String, sessionToken: String) -> LLMSessionEntry {
        registerUnchecked(providerID: providerID, sessionID: nil, sessionToken: sessionToken)
    }

    /// Register (or replace) a session token for one provider/session pair.
    /// Re-registering the same pair creates a new generation; the old entry
    /// remains a stale fact and is rejected by `accepts`.
    @discardableResult
    public func register(
        providerID: String,
        sessionID: String?,
        sessionToken: String
    ) -> LLMSessionEntry {
        registerUnchecked(
            providerID: providerID,
            sessionID: sessionID,
            sessionToken: sessionToken
        )
    }

    /// Register a provider/session binding with typed identity validation.
    /// The non-throwing compatibility overload intentionally becomes a
    /// fail-closed no-op for the same invalid inputs.
    @discardableResult
    public func registerValidated(
        providerID: String,
        sessionID: String? = nil,
        sessionToken: String
    ) throws -> LLMSessionEntry {
        guard Self.isValidIdentity(providerID) else {
            throw LLMSessionRegistryError.invalidProviderID(providerID)
        }
        if let sessionID, !Self.isValidIdentity(sessionID) {
            throw LLMSessionRegistryError.invalidSessionID(sessionID)
        }
        guard Self.isValidIdentity(sessionToken) else {
            throw LLMSessionRegistryError.invalidSessionToken
        }
        return registerUnchecked(
            providerID: providerID,
            sessionID: sessionID,
            sessionToken: sessionToken
        )
    }

    private static func isValidIdentity(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func registerUnchecked(
        providerID: String,
        sessionID: String?,
        sessionToken: String
    ) -> LLMSessionEntry {
        guard Self.isValidIdentity(providerID),
              sessionID.map(Self.isValidIdentity) ?? true,
              Self.isValidIdentity(sessionToken) else {
            return LLMSessionEntry(
                providerID: providerID,
                sessionToken: sessionToken,
                sessionID: sessionID
            )
        }
        let key = RegistryKey(providerID: providerID, sessionID: sessionID)
        lock.lock()
        guard !exhaustedKeys.contains(key) else {
            lock.unlock()
            return LLMSessionEntry(
                providerID: providerID,
                sessionToken: sessionToken,
                sessionID: sessionID,
                generation: .max
            )
        }
        let previousGeneration = generations[key] ?? 0
        guard previousGeneration < UInt64.max else {
            exhaustedKeys.insert(key)
            entries.removeValue(forKey: key)
            lock.unlock()
            return LLMSessionEntry(
                providerID: providerID,
                sessionToken: sessionToken,
                sessionID: sessionID,
                generation: .max
            )
        }
        let generation = previousGeneration + 1
        generations[key] = generation
        let bound = LLMSessionEntry(
            providerID: providerID,
            sessionToken: sessionToken,
            sessionID: sessionID,
            generation: generation
        )
        entries[key] = bound
        lock.unlock()
        return bound
    }

    /// All currently active sessions, oldest registration first.
    public func activeSessions() -> [LLMSessionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.sorted {
            if $0.registeredAt != $1.registeredAt {
                return $0.registeredAt < $1.registeredAt
            }
            return $0.stableID < $1.stableID
        }
    }

    /// The provider-level session token, or nil if the provider is only bound
    /// to session-specific entries (which must not be selected implicitly).
    public func sessionToken(for providerID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let matches = entries.values.filter {
            $0.providerID == providerID && $0.sessionID == nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0].sessionToken
    }

    /// Return the exact current entry for a provider/session identity.
    public func currentEntry(providerID: String, sessionID: String?) -> LLMSessionEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[RegistryKey(providerID: providerID, sessionID: sessionID)]
    }

    /// Whether an entry is still the current provider/session binding.
    /// Rebind, restart, or duplicate identity replacement makes old facts
    /// return false instead of selecting an arbitrary token.
    public func accepts(_ entry: LLMSessionEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = RegistryKey(
            providerID: entry.providerID,
            sessionID: entry.sessionID
        )
        guard !exhaustedKeys.contains(key), let current = entries[key] else {
            return false
        }
        return current.stableID == entry.stableID
            && current.sessionToken == entry.sessionToken
    }

    /// Whether a provider currently has an active session.
    public func isActive(providerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.contains { $0.providerID == providerID }
    }

    /// Whether the exact provider/session identity currently has a binding.
    public func isActive(providerID: String, sessionID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[RegistryKey(providerID: providerID, sessionID: sessionID)] != nil
    }

    /// Number of active sessions.
    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Drop a provider's session (e.g. on network transition or auth failure).
    public func invalidate(providerID: String) {
        lock.lock()
        entries = entries.filter { $0.key.providerID != providerID }
        lock.unlock()
    }

    /// Drop one provider/session binding while retaining its generation fence.
    public func invalidate(providerID: String, sessionID: String?) {
        lock.lock()
        entries.removeValue(forKey: RegistryKey(providerID: providerID, sessionID: sessionID))
        lock.unlock()
    }

    /// Drop every registered session.
    public func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

public enum LLMSessionRegistryError: Error, Equatable, Sendable {
    case invalidProviderID(String)
    case invalidSessionID(String)
    case invalidSessionToken
}
