import Foundation

/// Exact cache scope for one provider/model readiness observation.
///
/// `credentialVersion` is an opaque, secret-free version or digest supplied by
/// the credential owner.  It is deliberately part of the key: a readiness
/// result from an older App or credential binding must never satisfy a newer
/// lookup.
public struct ProviderReadinessCacheKey: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let credentialVersion: String
    /// Optional for backwards-compatible snapshots; absent means legacy.
    public let configurationGeneration: String?
    public let configurationFingerprint: String?

    public init(
        providerID: String,
        modelID: String,
        credentialVersion: String,
        configurationGeneration: String? = nil,
        configurationFingerprint: String? = nil
    ) {
        self.providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialVersion = credentialVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.configurationGeneration = configurationGeneration
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.configurationFingerprint = configurationFingerprint
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public var isValid: Bool {
        !providerID.isEmpty && !modelID.isEmpty && !credentialVersion.isEmpty
    }

    fileprivate var effectiveConfigurationGeneration: String {
        configurationGeneration ?? ProviderReadinessPersistenceRecord.legacyConfigurationGeneration
    }
}

/// One cache value paired with its exact provider/model/credential scope.
public struct ProviderReadinessCacheEntry: Codable, Equatable, Hashable, Sendable {
    public let key: ProviderReadinessCacheKey
    public let record: ProviderReadinessPersistenceRecord

    public init(
        key: ProviderReadinessCacheKey,
        record: ProviderReadinessPersistenceRecord
    ) {
        self.key = key
        self.record = record
    }
}

/// Secret-free readiness cache/index with precise credential scoping.
///
/// This index is intentionally independent from the durable readiness store:
/// callers can use it as a successor/App-local cache without changing the
/// existing persistence schema.  Rebinding one provider removes only that
/// provider's old credential-version entries; other providers and models are
/// untouched.
public struct ProviderReadinessCacheIndex: Codable, Equatable, Sendable {
    private var entriesByKey: [ProviderReadinessCacheKey: ProviderReadinessPersistenceRecord]

    public init(entries: [ProviderReadinessCacheEntry] = []) {
        self.entriesByKey = [:]
        for entry in entries where entry.key.isValid {
            let normalizedKey = ProviderReadinessCacheKey(
                providerID: entry.key.providerID,
                modelID: entry.key.modelID,
                credentialVersion: entry.key.credentialVersion,
                configurationGeneration: entry.key.effectiveConfigurationGeneration,
                configurationFingerprint: entry.key.configurationFingerprint
            )
            let scopedRecord = entry.record.providerID == normalizedKey.providerID
                && entry.record.modelID == normalizedKey.modelID
                && entry.record.configurationGeneration == normalizedKey.effectiveConfigurationGeneration
                && entry.record.configurationFingerprint == normalizedKey.configurationFingerprint
                ? entry.record
                : entry.record.downgradedToUnverified()
            guard let current = entriesByKey[normalizedKey] else {
                entriesByKey[normalizedKey] = scopedRecord
                continue
            }
            entriesByKey[normalizedKey] = mergeDuplicate(current, with: scopedRecord)
        }
    }

    public var entries: [ProviderReadinessCacheEntry] {
        entriesByKey.map { ProviderReadinessCacheEntry(key: $0.key, record: $0.value) }
            .sorted {
                if $0.key.providerID != $1.key.providerID {
                    return $0.key.providerID < $1.key.providerID
                }
                if $0.key.modelID != $1.key.modelID {
                    return $0.key.modelID < $1.key.modelID
                }
                if $0.key.credentialVersion != $1.key.credentialVersion {
                    return $0.key.credentialVersion < $1.key.credentialVersion
                }
                return $0.key.effectiveConfigurationGeneration
                    < $1.key.effectiveConfigurationGeneration
            }
    }

    public func record(
        providerID: String,
        modelID: String,
        credentialVersion: String,
        configurationGeneration: String = ProviderReadinessPersistenceRecord
            .legacyConfigurationGeneration
    ) -> ProviderReadinessPersistenceRecord? {
        let key = ProviderReadinessCacheKey(
            providerID: providerID,
            modelID: modelID,
            credentialVersion: credentialVersion,
            configurationGeneration: configurationGeneration
        )
        guard key.isValid else { return nil }
        // Without the expected configuration identity and clock, this legacy
        // lookup cannot authorize a green fact. Keep the entry inspectable but
        // fail closed until the strict overload is used.
        return entriesByKey[key]?.downgradedToUnverified()
    }

    /// Strict lookup binds provider/model/credential/configuration identity
    /// and freshness. A drifted or stale entry is returned as unverified so a
    /// consumer can explain the state without reusing its former green fact.
    public func record(
        providerID: String,
        modelID: String,
        credentialVersion: String,
        configurationFingerprint: String,
        now: Date,
        configurationGeneration: String = ProviderReadinessPersistenceRecord
            .legacyConfigurationGeneration
    ) -> ProviderReadinessPersistenceRecord? {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVersion = credentialVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGeneration = configurationGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty,
              !normalizedModelID.isEmpty,
              !normalizedVersion.isEmpty,
              !normalizedGeneration.isEmpty else { return nil }

        let normalizedFingerprint = configurationFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = entriesByKey.filter {
            $0.key.providerID == normalizedProviderID
                && $0.key.modelID == normalizedModelID
                && $0.key.credentialVersion == normalizedVersion
                && $0.key.effectiveConfigurationGeneration == normalizedGeneration
        }
        guard let pair = scoped.sorted(by: { lhs, rhs in
            let lhsExact = lhs.key.configurationFingerprint == normalizedFingerprint
            let rhsExact = rhs.key.configurationFingerprint == normalizedFingerprint
            if lhsExact != rhsExact { return lhsExact }
            return lhs.value.checkedAt > rhs.value.checkedAt
        }).first else {
            return nil
        }
        guard pair.key.configurationFingerprint == normalizedFingerprint else {
            return pair.value.downgradedToUnverified()
        }
        guard pair.value.configurationGeneration == normalizedGeneration else {
            return pair.value.downgradedToUnverified()
        }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              now >= pair.value.checkedAt else {
            return pair.value.downgradedToUnverified()
        }
        return pair.value.validatedForCache(
            configurationFingerprint: configurationFingerprint,
            now: now,
            configurationGeneration: normalizedGeneration
        )
    }

    @discardableResult
    public mutating func upsert(
        _ record: ProviderReadinessPersistenceRecord,
        credentialVersion: String,
        configurationGeneration: String? = nil,
        configurationFingerprint: String? = nil
    ) -> Bool {
        let key = ProviderReadinessCacheKey(
            providerID: record.providerID,
            modelID: record.modelID,
            credentialVersion: credentialVersion,
            configurationGeneration: configurationGeneration ?? record.configurationGeneration,
            configurationFingerprint: configurationFingerprint ?? record.configurationFingerprint
        )
        guard key.isValid,
              record.providerID == key.providerID,
              record.modelID == key.modelID,
              record.configurationGeneration == key.effectiveConfigurationGeneration,
              record.configurationFingerprint == key.configurationFingerprint,
              record.checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        if let current = entriesByKey[key] {
            guard record.checkedAt >= current.checkedAt else {
                return false
            }
            guard record.checkedAt != current.checkedAt || record == current else {
                return false
            }
        }
        entriesByKey[key] = record
        return true
    }

    private func mergeDuplicate(
        _ current: ProviderReadinessPersistenceRecord,
        with candidate: ProviderReadinessPersistenceRecord
    ) -> ProviderReadinessPersistenceRecord {
        if current.checkedAt > candidate.checkedAt { return current }
        if candidate.checkedAt > current.checkedAt { return candidate }
        guard current != candidate else { return current }
        let selected = Self.tieBreakKey(current) <= Self.tieBreakKey(candidate)
            ? current
            : candidate
        return selected.downgradedToUnverified()
    }

    private static func tieBreakKey(
        _ record: ProviderReadinessPersistenceRecord
    ) -> String {
        [
            record.providerID,
            record.modelID,
            record.configurationGeneration,
            record.status.rawValue,
            record.readinessState.rawValue,
            String(record.checkedAt.timeIntervalSinceReferenceDate),
            record.errorCategory?.rawValue ?? "",
            String(record.latency ?? -1),
            record.evidenceID ?? "",
            String(record.isApplied),
            record.configurationFingerprint ?? "",
            record.expiresAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
        ].joined(separator: "\u{1F}")
    }

    /// Drops only the exact provider/model/credential-version entry.
    @discardableResult
    public mutating func invalidate(
        providerID: String,
        modelID: String,
        credentialVersion: String
    ) -> Bool {
        let key = ProviderReadinessCacheKey(
            providerID: providerID,
            modelID: modelID,
            credentialVersion: credentialVersion
        )
        guard key.isValid else { return false }
        let matchingKeys = entriesByKey.keys.filter {
            $0.providerID == key.providerID
                && $0.modelID == key.modelID
                && $0.credentialVersion == key.credentialVersion
        }
        for matchingKey in matchingKeys {
            entriesByKey.removeValue(forKey: matchingKey)
        }
        return !matchingKeys.isEmpty
    }

    /// Successor rebind invalidation for one provider.
    ///
    /// Every old credential-version entry for this provider is removed, while
    /// entries for other providers remain available.  The new version is not
    /// fabricated or implicitly populated.
    @discardableResult
    public mutating func invalidateForSuccessorRebind(
        providerID: String,
        newCredentialVersion: String
    ) -> Int {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVersion = newCredentialVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty, !normalizedVersion.isEmpty else {
            return 0
        }
        let staleKeys = entriesByKey.keys.filter {
            $0.providerID.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
                && $0.credentialVersion != normalizedVersion
        }
        for key in staleKeys {
            entriesByKey.removeValue(forKey: key)
        }
        return staleKeys.count
    }

    /// Removes all cached readiness for one provider without touching others.
    @discardableResult
    public mutating func removeProvider(providerID: String) -> Int {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = entriesByKey.keys.filter {
            $0.providerID.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }
        for key in keys {
            entriesByKey.removeValue(forKey: key)
        }
        return keys.count
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decodeIfPresent(
            [ProviderReadinessCacheEntry].self,
            forKey: .entries
        ) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }
}

/// Durable cache wrapper used by the readiness production consumer.
///
/// The cache is a convenience index, never the authority for credentials or
/// model selection.  It uses the same atomic snapshot boundary as the main
/// readiness store and quarantines malformed input before reopening empty.
public final class ProviderReadinessCacheStore: @unchecked Sendable {
    public static let fileName = "provider-readiness-cache.json"
    public static let schemaVersion = 1

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let index: ProviderReadinessCacheIndex
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var index: ProviderReadinessCacheIndex
    public private(set) var recoveryState: ProviderReadinessStoreRecoveryState = .missing

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.index = ProviderReadinessCacheIndex()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        load()
    }

    public var entries: [ProviderReadinessCacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        return index.entries
    }

    public func record(
        providerID: String,
        modelID: String,
        credentialVersion: String,
        configurationGeneration: String = ProviderReadinessPersistenceRecord
            .legacyConfigurationGeneration
    ) -> ProviderReadinessPersistenceRecord? {
        lock.lock()
        defer { lock.unlock() }
        return index.record(
            providerID: providerID,
            modelID: modelID,
            credentialVersion: credentialVersion,
            configurationGeneration: configurationGeneration
        )
    }

    /// Strict production read bound to configuration identity and expiry.
    public func record(
        providerID: String,
        modelID: String,
        credentialVersion: String,
        configurationFingerprint: String,
        now: Date,
        configurationGeneration: String = ProviderReadinessPersistenceRecord
            .legacyConfigurationGeneration
    ) -> ProviderReadinessPersistenceRecord? {
        lock.lock()
        defer { lock.unlock() }
        return index.record(
            providerID: providerID,
            modelID: modelID,
            credentialVersion: credentialVersion,
            configurationFingerprint: configurationFingerprint,
            now: now,
            configurationGeneration: configurationGeneration
        )
    }

    @discardableResult
    public func upsert(
        _ record: ProviderReadinessPersistenceRecord,
        credentialVersion: String,
        configurationGeneration: String? = nil,
        configurationFingerprint: String? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard index.upsert(
            record,
            credentialVersion: credentialVersion,
            configurationGeneration: configurationGeneration,
            configurationFingerprint: configurationFingerprint
        ) else {
            return false
        }
        persistLocked()
        return true
    }

    @discardableResult
    public func invalidateForSuccessorRebind(
        providerID: String,
        newCredentialVersion: String
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let removed = index.invalidateForSuccessorRebind(
            providerID: providerID,
            newCredentialVersion: newCredentialVersion
        )
        if removed > 0 {
            persistLocked()
        }
        return removed
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            recoveryState = .missing
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == Self.schemaVersion else {
            quarantineCorruptSnapshot()
            recoveryState = .quarantinedCorrupt
            return
        }
        index = snapshot.index
        recoveryState = .loaded(recordCount: index.entries.count)
    }

    private func persistLocked() {
        let snapshot = Snapshot(schemaVersion: Self.schemaVersion, index: index)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func quarantineCorruptSnapshot() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let quarantineURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString)"
        )
        try? FileManager.default.moveItem(at: fileURL, to: quarantineURL)
    }
}
